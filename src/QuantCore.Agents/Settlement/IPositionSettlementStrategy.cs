using QuantCore.Contracts.Domain;

namespace QuantCore.Agents.Settlement;

public sealed record ActiveAgentContext(
    Guid RunId,
    Guid PoolInstanceId,
    Guid AgentId,
    string ActorType,
    string ProfileKey,
    int ReplicaIndex,
    string JitterDeltaJson,
    IReadOnlyList<ExecutedMoveRecord> ExecutedMoves,
    decimal RealizedPnlUsdt,
    decimal MaxDrawdownPct,
    decimal SharpeEstimate,
    IReadOnlyDictionary<string, decimal> OpenSymbolQuantities,
    IReadOnlyDictionary<string, decimal> LatestMarketPrices
);

public interface IPositionSettlementStrategy
{
    string StrategyName { get; }
    Task<EpisodeCommitResponse?> SettleEpisodeAsync(ActiveAgentContext context, CancellationToken ct);
}
