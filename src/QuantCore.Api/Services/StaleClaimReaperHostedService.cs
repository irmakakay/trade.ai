using System.Collections.Concurrent;
using System.Data;
using Dapper;
using QuantCore.Api.Messaging;
using QuantCore.Contracts.Messaging;

namespace QuantCore.Api.Services;

/// <summary>
/// Periodically self-heals orphaned strategy_pool CLAIMED slots, leaked strategy_allocations,
/// expired portfolio_inventory locks, and starved profiles after agent/worker restarts.
/// </summary>
public sealed class StaleClaimReaperHostedService : BackgroundService
{
    private readonly Func<IDbConnection> _dbFactory;
    private readonly IRabbitMqQueueService _mq;
    private readonly IConfiguration _config;
    private readonly ILogger<StaleClaimReaperHostedService> _logger;
    private readonly ConcurrentDictionary<string, DateTimeOffset> _lastRecalcTrigger = new(StringComparer.OrdinalIgnoreCase);

    public StaleClaimReaperHostedService(
        Func<IDbConnection> dbFactory,
        IRabbitMqQueueService mq,
        IConfiguration config,
        ILogger<StaleClaimReaperHostedService> logger)
    {
        _dbFactory = dbFactory;
        _mq = mq;
        _config = config;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        int claimTtlSeconds = Math.Max(30, _config.GetValue<int>("CLAIM_TTL_SECONDS", 90));
        int intervalSeconds = Math.Max(5, _config.GetValue<int>("REAPER_INTERVAL_SECONDS", 15));
        int starvedGraceSeconds = Math.Max(30, _config.GetValue<int>("STARVED_POOL_GRACE_SECONDS", 45));

        _logger.LogInformation(
            "[StaleClaimReaper] Started | ClaimTtl={Ttl}s | SweepInterval={Interval}s | StarvedGrace={Grace}s",
            claimTtlSeconds, intervalSeconds, starvedGraceSeconds);

        try
        {
            // Brief startup delay so PoolWarmupHostedService completes initial seeding first
            await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            return;
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await RunReaperSweepAsync(claimTtlSeconds, starvedGraceSeconds, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "[StaleClaimReaper] Non-fatal sweep error; will retry next cycle.");
            }

            try
            {
                await Task.Delay(TimeSpan.FromSeconds(intervalSeconds), stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
        }
    }

    private async Task RunReaperSweepAsync(int claimTtlSeconds, int starvedGraceSeconds, CancellationToken ct)
    {
        List<string> starvedProfiles;

        using (var conn = _dbFactory())
        {
            conn.Open();
            using var tx = conn.BeginTransaction();

            // 1. Any AVAILABLE/CLAIMED row already referenced by trading_history is COMPLETED
            const string reconcileCompletedSql = @"
                UPDATE strategy_pool sp
                SET status = 'COMPLETED'
                WHERE sp.status IN ('AVAILABLE', 'CLAIMED')
                  AND EXISTS (
                      SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id
                  );";
            int reconciled = await conn.ExecuteAsync(
                new CommandDefinition(reconcileCompletedSql, transaction: tx, cancellationToken: ct));

            // 2. Reclaim orphaned CLAIMED slots whose agent died or exceeded CLAIM_TTL_SECONDS
            const string reclaimClaimsSql = @"
                WITH stale_claims AS (
                    SELECT sp.pool_instance_id
                    FROM strategy_pool sp
                    WHERE sp.status = 'CLAIMED'
                      AND COALESCE(sp.claimed_at, sp.created_at) < NOW() - make_interval(secs => @ClaimTtlSeconds)
                      AND NOT EXISTS (
                          SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id
                      )
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE strategy_pool sp
                SET status = 'AVAILABLE',
                    claimed_by_agent_id = NULL,
                    claimed_at = NULL
                FROM stale_claims sc
                WHERE sp.pool_instance_id = sc.pool_instance_id
                RETURNING sp.pool_instance_id;";

            var reclaimedIds = (await conn.QueryAsync<Guid>(
                new CommandDefinition(reclaimClaimsSql, new { ClaimTtlSeconds = claimTtlSeconds }, tx, cancellationToken: ct)))
                .ToArray();

            // 3. Release orphaned ACTIVE slice allocations and restore portfolio_inventory.allocated_quantity
            const string releaseAllocationsSql = @"
                WITH released AS (
                    UPDATE strategy_allocations
                    SET status = 'RELEASED'
                    WHERE status = 'ACTIVE'
                      AND (
                          strategy_id = ANY(@ReclaimedPoolIds)
                          OR created_at < NOW() - make_interval(secs => @ClaimTtlSeconds)
                      )
                    RETURNING symbol, reserved_quantity
                ),
                agg AS (
                    SELECT symbol, SUM(reserved_quantity) AS total_released
                    FROM released
                    GROUP BY symbol
                )
                UPDATE portfolio_inventory pi
                SET allocated_quantity = GREATEST(0, pi.allocated_quantity - agg.total_released),
                    updated_at = NOW()
                FROM agg
                WHERE pi.symbol = agg.symbol;";

            int inventoryRestored = await conn.ExecuteAsync(
                new CommandDefinition(
                    releaseAllocationsSql,
                    new { ReclaimedPoolIds = reclaimedIds, ClaimTtlSeconds = claimTtlSeconds },
                    tx,
                    cancellationToken: ct));

            // 4. Clear expired short-TTL inventory mutex locks
            const string clearExpiredLocksSql = @"
                UPDATE portfolio_inventory
                SET locked_by_agent = NULL,
                    lock_acquired_at = NULL,
                    lock_expires_at = NULL,
                    updated_at = NOW()
                WHERE locked_by_agent IS NOT NULL
                  AND lock_expires_at IS NOT NULL
                  AND lock_expires_at < NOW();";

            int expiredLocksCleared = await conn.ExecuteAsync(
                new CommandDefinition(clearExpiredLocksSql, transaction: tx, cancellationToken: ct));

            // 5. Detect profiles with zero active slots past grace window (e.g., missed MQ message)
            const string starvedProfilesSql = @"
                WITH profiles(profile_key) AS (
                    VALUES ('AGGRESSIVE_BREAKOUT'), ('BALANCED_SWING'), ('CAREFUL_MEAN_REVERSION')
                )
                SELECT p.profile_key
                FROM profiles p
                WHERE NOT EXISTS (
                    SELECT 1 FROM strategy_pool sp
                    WHERE sp.profile_key = p.profile_key
                      AND sp.status IN ('AVAILABLE', 'CLAIMED')
                )
                AND NOT EXISTS (
                    SELECT 1 FROM strategy_pool sp
                    WHERE sp.profile_key = p.profile_key
                      AND sp.created_at >= NOW() - make_interval(secs => @StarvedGraceSeconds)
                );";

            starvedProfiles = (await conn.QueryAsync<string>(
                new CommandDefinition(starvedProfilesSql, new { StarvedGraceSeconds = starvedGraceSeconds }, tx, cancellationToken: ct)))
                .ToList();

            tx.Commit();

            if (reconciled > 0 || reclaimedIds.Length > 0 || inventoryRestored > 0 || expiredLocksCleared > 0)
            {
                _logger.LogWarning(
                    "[StaleClaimReaper] Self-healed DB | ReclaimedClaims={Claims} | ReconciledCompleted={Comp} | InventorySymbolsRestored={Inv} | ExpiredLocks={Locks}",
                    reclaimedIds.Length, reconciled, inventoryRestored, expiredLocksCleared);
            }
        }

        // Trigger pool regeneration outside the DB transaction for any starved profile (with cooldown)
        int kFactor = _config.GetValue<int>("POOL_REPLICATION_FACTOR", 3);
        var now = DateTimeOffset.UtcNow;
        foreach (string profileKey in starvedProfiles)
        {
            if (_lastRecalcTrigger.TryGetValue(profileKey, out var lastRun) &&
                (now - lastRun).TotalSeconds < starvedGraceSeconds)
            {
                continue;
            }

            _lastRecalcTrigger[profileKey] = now;
            decimal profileRiskDial = profileKey switch
            {
                "CAREFUL_MEAN_REVERSION" => 0.25m,
                "BALANCED_SWING" => 0.50m,
                _ => 0.75m
            };

            _mq.SubmitTaskToInputQueue(new InputTaskMessage(
                Guid.NewGuid(),
                TaskCommandType.RECALCULATE_POOL,
                profileKey,
                profileRiskDial,
                kFactor,
                new[] { "BTCUSDT", "ETHUSDT", "SOLUSDT" },
                now
            ));

            _logger.LogWarning("[StaleClaimReaper] Re-queued RECALCULATE_POOL for starved profile {Profile}", profileKey);
        }
    }
}
