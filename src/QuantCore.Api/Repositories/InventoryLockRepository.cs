using System.Data;
using Dapper;
using QuantCore.Contracts.Domain;

namespace QuantCore.Api.Repositories;

public interface IInventoryLockRepository
{
    Task<ShareSliceClaimResult> ClaimSymbolSliceAtomicAsync(ShareSliceClaimRequest req, int lockTtlSeconds, CancellationToken ct);
}

public sealed class InventoryLockRepository : IInventoryLockRepository
{
    private readonly Func<IDbConnection> _connectionFactory;

    public InventoryLockRepository(Func<IDbConnection> connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<ShareSliceClaimResult> ClaimSymbolSliceAtomicAsync(
        ShareSliceClaimRequest req,
        int lockTtlSeconds,
        CancellationToken ct)
    {
        if (req.RequestedFractionPct <= 0m || req.RequestedFractionPct > 1.0m)
        {
            return new ShareSliceClaimResult(false, req.Symbol, 0m, 0m, "INVALID_FRACTION_BOUNDS");
        }

        using var conn = _connectionFactory();
        conn.Open();
        using var tx = conn.BeginTransaction(IsolationLevel.ReadCommitted);

        // Step 1: Acquire short-lived First-Wins mutex (self-heals if prior lock expired)
        const string acquireSql = @"
            UPDATE portfolio_inventory
            SET locked_by_agent = @AgentId,
                lock_acquired_at = NOW(),
                lock_expires_at = NOW() + (@TtlSeconds || ' seconds')::interval
            WHERE symbol = @Symbol
              AND (locked_by_agent IS NULL OR lock_expires_at < NOW())
            RETURNING total_quantity AS TotalQty, allocated_quantity AS AllocatedQty;";

        var lockRow = await conn.QuerySingleOrDefaultAsync<(decimal TotalQty, decimal AllocatedQty)?>(
            new CommandDefinition(acquireSql, new { req.AgentId, req.Symbol, TtlSeconds = lockTtlSeconds }, tx, cancellationToken: ct));

        if (lockRow is null)
        {
            tx.Rollback();
            return new ShareSliceClaimResult(false, req.Symbol, 0m, 0m, "SYMBOL_LOCKED_BY_RULING_AGENT");
        }

        decimal unallocated = lockRow.Value.TotalQty - lockRow.Value.AllocatedQty;
        decimal sliceQty = Math.Round(unallocated * req.RequestedFractionPct, 10, MidpointRounding.ToZero);

        if (sliceQty <= 0m)
        {
            const string unlockEmptySql = @"
                UPDATE portfolio_inventory
                SET locked_by_agent = NULL, lock_expires_at = NULL
                WHERE symbol = @Symbol;";
            await conn.ExecuteAsync(new CommandDefinition(unlockEmptySql, new { req.Symbol }, tx, cancellationToken: ct));
            tx.Commit();
            return new ShareSliceClaimResult(false, req.Symbol, 0m, unallocated, "ZERO_UNALLOCATED_INVENTORY");
        }

        // Step 2: Record Strategy Slice Allocation & Immediately Release Symbol Mutex
        const string allocateAndReleaseSql = @"
            INSERT INTO strategy_allocations (allocation_id, symbol, agent_id, strategy_id, reserved_quantity, status)
            VALUES (@AllocationId, @Symbol, @AgentId, @StrategyId, @SliceQty, 'ACTIVE');

            UPDATE portfolio_inventory
            SET allocated_quantity = allocated_quantity + @SliceQty,
                directional_bias = @DirectionalBias,
                locked_by_agent = NULL,
                lock_acquired_at = NULL,
                lock_expires_at = NULL,
                updated_at = NOW()
            WHERE symbol = @Symbol;";

        await conn.ExecuteAsync(new CommandDefinition(
            allocateAndReleaseSql,
            new
            {
                AllocationId = Guid.NewGuid(),
                req.Symbol,
                req.AgentId,
                req.StrategyId,
                SliceQty = sliceQty,
                req.DirectionalBias
            },
            tx,
            cancellationToken: ct));

        tx.Commit();
        return new ShareSliceClaimResult(true, req.Symbol, sliceQty, unallocated - sliceQty, "SLICE_LOCKED_AND_MUTEX_RELEASED");
    }
}
