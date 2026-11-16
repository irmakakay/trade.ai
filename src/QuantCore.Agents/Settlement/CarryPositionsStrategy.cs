using QuantCore.Agents.Client;
using QuantCore.Contracts.Domain;

namespace QuantCore.Agents.Settlement;

public sealed class CarryPositionsStrategy : IPositionSettlementStrategy
{
    private readonly IQuantApiClient _apiClient;

    public string StrategyName => "CARRY_POSITIONS";

    public CarryPositionsStrategy(IQuantApiClient apiClient)
    {
        _apiClient = apiClient;
    }

    public async Task<EpisodeCommitResponse?> SettleEpisodeAsync(ActiveAgentContext context, CancellationToken ct)
    {
        var commitReq = new EpisodeCommitRequest(
            RunId: context.RunId,
            PoolInstanceId: context.PoolInstanceId,
            IdentityId: context.AgentId,
            ActorType: context.ActorType,
            ProfileKey: context.ProfileKey,
            ReplicaIndex: context.ReplicaIndex,
            JitterDeltaJson: context.JitterDeltaJson,
            ExecutedMoves: context.ExecutedMoves,
            RealizedPnlUsdt: context.RealizedPnlUsdt,
            MaxDrawdownPct: context.MaxDrawdownPct,
            SharpeEstimate: context.SharpeEstimate,
            LiquidateAndReleaseSlices: false
        );

        return await _apiClient.CommitEpisodeHistoryAsync(commitReq, ct);
    }
}
