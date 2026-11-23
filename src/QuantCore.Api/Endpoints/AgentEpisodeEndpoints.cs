using System.Data;
using System.Text.Json;
using Dapper;
using QuantCore.Api.Messaging;
using QuantCore.Api.Services;
using QuantCore.Contracts.Domain;
using QuantCore.Contracts.Messaging;

namespace QuantCore.Api.Endpoints;

public static class AgentEpisodeEndpoints
{
    public static IEndpointRouteBuilder MapAgentEpisodeEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapPost("/api/v1/episodes/commit", async (
            EpisodeCommitRequest req,
            Func<IDbConnection> dbFactory,
            IRabbitMqQueueService mq,
            MarketStreamGateway stream,
            IConfiguration cfg,
            CancellationToken ct) =>
        {
            using var conn = dbFactory();
            conn.Open();
            using var tx = conn.BeginTransaction();

            // 1. Ensure trading_identities record exists
            const string upsertIdentitySql = @"
                INSERT INTO trading_identities (identity_id, actor_type, profile_key)
                VALUES (@IdentityId, @ActorType, @ProfileKey)
                ON CONFLICT (identity_id) DO NOTHING;";
            await conn.ExecuteAsync(new CommandDefinition(
                upsertIdentitySql, new { req.IdentityId, req.ActorType, req.ProfileKey }, tx, cancellationToken: ct));

            // 2. Insert completed episode into trading_history & mark strategy_pool slot COMPLETED
            const string insertHistorySql = @"
                INSERT INTO trading_history
                    (run_id, pool_instance_id, identity_id, profile_key, replica_index, jitter_delta, executed_moves, realized_pnl_usdt, max_drawdown_pct, sharpe_estimate)
                VALUES
                    (@RunId, @PoolInstanceId, @IdentityId, @ProfileKey, @ReplicaIndex, @JitterDeltaJson::jsonb, @MovesJson::jsonb, @RealizedPnlUsdt, @MaxDrawdownPct, @SharpeEstimate);

                UPDATE strategy_pool
                SET status = 'COMPLETED'
                WHERE pool_instance_id = @PoolInstanceId;";

            await conn.ExecuteAsync(new CommandDefinition(
                insertHistorySql,
                new
                {
                    req.RunId,
                    req.PoolInstanceId,
                    req.IdentityId,
                    req.ProfileKey,
                    req.ReplicaIndex,
                    req.JitterDeltaJson,
                    MovesJson = JsonSerializer.Serialize(req.ExecutedMoves),
                    req.RealizedPnlUsdt,
                    req.MaxDrawdownPct,
                    req.SharpeEstimate
                },
                tx,
                cancellationToken: ct));

            // 3. If LiquidateAndReleaseSlices == true, release active strategy_allocations back to portfolio_inventory
            int releasedCount = 0;
            // Always release DB slice reservation at episode boundary so next generation is never starved
            {
                const string releaseSlicesSql = @"
                    WITH released AS (
                        UPDATE strategy_allocations
                        SET status = 'RELEASED'
                        WHERE agent_id = @IdentityId AND status = 'ACTIVE'
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

                releasedCount = await conn.ExecuteAsync(new CommandDefinition(releaseSlicesSql, new { req.IdentityId }, tx, cancellationToken: ct));
            }

            // 4. Check if all K replicas for this profile have finished; if so, trigger evolutionary RECALCULATE_POOL
            const string remainingActiveSql = @"
                SELECT COUNT(1)
                FROM strategy_pool
                WHERE profile_key = @ProfileKey
                  AND status IN ('AVAILABLE', 'CLAIMED');";

            int remaining = await conn.ExecuteScalarAsync<int>(
                new CommandDefinition(remainingActiveSql, new { req.ProfileKey }, tx, cancellationToken: ct));

            tx.Commit();

            bool triggeredRecalc = false;
            if (remaining == 0)
            {
                int kFactor = cfg.GetValue<int>("POOL_REPLICATION_FACTOR", 3);
                decimal profileRiskDial = req.ProfileKey.Trim().ToUpperInvariant() switch
                {
                    "CAREFUL_MEAN_REVERSION" => 0.25m,
                    "BALANCED_SWING" => 0.50m,
                    _ => 0.75m
                };
                mq.SubmitTaskToInputQueue(new InputTaskMessage(
                    Guid.NewGuid(),
                    TaskCommandType.RECALCULATE_POOL,
                    req.ProfileKey,
                    profileRiskDial,
                    kFactor,
                    new[] { "BTCUSDT", "ETHUSDT", "SOLUSDT" },
                    DateTimeOffset.UtcNow
                ));
                triggeredRecalc = true;
            }

            stream.PublishFrame(new LiveStreamFrame(
                "EPISODE_COMMITTED",
                req.ProfileKey,
                req.RealizedPnlUsdt,
                req.IdentityId,
                req.LiquidateAndReleaseSlices ? "LIQUIDATED" : "CARRIED",
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));

            return Results.Ok(new EpisodeCommitResponse(true, req.RunId, releasedCount, triggeredRecalc));
        });

        app.MapPost("/api/v1/episodes/reset", (EpisodeResetCommand cmd, MarketStreamGateway stream) =>
        {
            stream.PublishFrame(new LiveStreamFrame(
                "FORCE_EPISODE_RESET",
                cmd.ProfileKey ?? "ALL",
                0m,
                null,
                cmd.Reason,
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
            return Results.Ok(new { broadcasted = true, cmd.Reason });
        });


        app.MapGet("/api/v1/episodes/summary", async (Func<IDbConnection> dbFactory, CancellationToken ct) =>
        {
            using var conn = dbFactory();
            conn.Open();

            const string kpiSql = @"
                SELECT
                    COUNT(1) AS total_episodes,
                    COALESCE(SUM(realized_pnl_usdt), 0) AS total_pnl_usdt,
                    COALESCE(AVG(sharpe_estimate), 0) AS avg_sharpe,
                    COALESCE(MAX(max_drawdown_pct), 0) AS worst_drawdown_pct,
                    (SELECT COUNT(1) FROM nn_model_checkpoints) AS total_checkpoints
                FROM trading_history;";

            var kpis = await conn.QuerySingleAsync(new CommandDefinition(kpiSql, cancellationToken: ct));

            const string recentEpisodesSql = @"
                SELECT run_id, profile_key, replica_index, realized_pnl_usdt, max_drawdown_pct, sharpe_estimate, completed_at
                FROM trading_history
                ORDER BY completed_at DESC
                LIMIT 15;";

            var recentEpisodes = await conn.QueryAsync(new CommandDefinition(recentEpisodesSql, cancellationToken: ct));

            const string nnCheckpointsSql = @"
                SELECT model_id, version_tag, confidence_score, is_promoted_live, created_at
                FROM nn_model_checkpoints
                ORDER BY created_at DESC
                LIMIT 8;";

            var checkpoints = await conn.QueryAsync(new CommandDefinition(nnCheckpointsSql, cancellationToken: ct));

            const string poolStateSql = @"
                SELECT DISTINCT ON (profile_key, replica_index)
                    profile_key, replica_index, status, risk_dial_r, strategy_payload::text AS strategy_payload
                FROM strategy_pool
                WHERE status IN ('AVAILABLE', 'CLAIMED')
                ORDER BY profile_key, replica_index, created_at DESC;";

            var poolState = await conn.QueryAsync(new CommandDefinition(poolStateSql, cancellationToken: ct));

            return Results.Ok(new
            {
                kpis,
                recent_episodes = recentEpisodes,
                nn_checkpoints = checkpoints,
                pool_state = poolState
            });
        });

        app.MapGet("/api/v1/market/ohlcv-window", (int? limit, MarketStreamGateway stream) =>
        {
            var snapshot = stream.GetOhlcvSnapshot(limit ?? 32);
            return Results.Ok(new { candles_by_symbol = snapshot });
        });

        return app;
    }
}
