using System.Data;
using Dapper;
using QuantCore.Contracts.Domain;

namespace QuantCore.Api.Repositories;

public interface IStrategyPoolRepository
{
    Task<PoolSlotDto?> CheckoutNextAvailableSlotAsync(Guid agentId, string profileKey, CancellationToken ct);
    Task<int> GetAvailablePoolCountAsync(CancellationToken ct);
}

public sealed class StrategyPoolRepository : IStrategyPoolRepository
{
    private readonly Func<IDbConnection> _connectionFactory;

    public StrategyPoolRepository(Func<IDbConnection> connectionFactory)
    {
        _connectionFactory = connectionFactory;
    }

    public async Task<PoolSlotDto?> CheckoutNextAvailableSlotAsync(Guid agentId, string profileKey, CancellationToken ct)
    {
        const string sql = @"
            WITH target_slot AS (
                SELECT pool_instance_id
                FROM strategy_pool
                WHERE profile_key = @ProfileKey
                  AND status = 'AVAILABLE'
                ORDER BY replica_index ASC
                LIMIT 1
                FOR UPDATE SKIP LOCKED
            )
            UPDATE strategy_pool sp
            SET status = 'CLAIMED',
                claimed_by_agent_id = @AgentId,
                claimed_at = NOW()
            FROM target_slot
            WHERE sp.pool_instance_id = target_slot.pool_instance_id
            RETURNING
                sp.pool_instance_id AS PoolInstanceId,
                sp.profile_key AS ProfileKey,
                sp.replica_index AS ReplicaIndex,
                sp.risk_dial_r AS RiskDialR,
                sp.jitter_delta::text AS JitterDeltaJson,
                sp.strategy_payload::text AS StrategyPayloadJson,
                sp.candidate_symbols::text AS CandidateSymbolsJson;";

        using var conn = _connectionFactory();
        var cmd = new CommandDefinition(sql, new { ProfileKey = profileKey, AgentId = agentId }, cancellationToken: ct);
        return await conn.QuerySingleOrDefaultAsync<PoolSlotDto>(cmd);
    }

    public async Task<int> GetAvailablePoolCountAsync(CancellationToken ct)
    {
        const string sql = "SELECT COUNT(1) FROM strategy_pool WHERE status = 'AVAILABLE';";
        using var conn = _connectionFactory();
        return await conn.ExecuteScalarAsync<int>(new CommandDefinition(sql, cancellationToken: ct));
    }
}
