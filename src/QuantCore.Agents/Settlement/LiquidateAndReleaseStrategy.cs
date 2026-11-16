using QuantCore.Agents.Client;
using QuantCore.Contracts.Domain;

namespace QuantCore.Agents.Settlement;

public sealed class LiquidateAndReleaseStrategy : IPositionSettlementStrategy
{
    private const decimal TakerFeeRate = 0.0010m;
    private readonly IQuantApiClient _apiClient;

    public string StrategyName => "LIQUIDATE_AND_RELEASE";

    public LiquidateAndReleaseStrategy(IQuantApiClient apiClient)
    {
        _apiClient = apiClient;
    }

    public async Task<EpisodeCommitResponse?> SettleEpisodeAsync(ActiveAgentContext context, CancellationToken ct)
    {
        var finalMoves = new List<ExecutedMoveRecord>(context.ExecutedMoves);
        decimal liquidationPnlAdjustment = 0m;
        long nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        foreach (var (symbol, qty) in context.OpenSymbolQuantities)
        {
            if (qty <= 0m) continue;
            decimal markPrice = context.LatestMarketPrices.TryGetValue(symbol, out var p) ? p : 100m;
            decimal grossProceeds = qty * markPrice;
            decimal fee = Math.Round(grossProceeds * TakerFeeRate, 8);
            liquidationPnlAdjustment -= fee;

            finalMoves.Add(new ExecutedMoveRecord(
                Symbol: symbol,
                Action: "SELL_LIQUIDATE_EOP",
                Quantity: qty,
                FillPrice: markPrice,
                FeeUsdt: fee,
                TimestampMs: nowMs
            ));
        }

        var commitReq = new EpisodeCommitRequest(
            RunId: context.RunId,
            PoolInstanceId: context.PoolInstanceId,
            IdentityId: context.AgentId,
            ActorType: context.ActorType,
            ProfileKey: context.ProfileKey,
            ReplicaIndex: context.ReplicaIndex,
            JitterDeltaJson: context.JitterDeltaJson,
            ExecutedMoves: finalMoves,
            RealizedPnlUsdt: context.RealizedPnlUsdt + liquidationPnlAdjustment,
            MaxDrawdownPct: context.MaxDrawdownPct,
            SharpeEstimate: context.SharpeEstimate,
            LiquidateAndReleaseSlices: true
        );

        return await _apiClient.CommitEpisodeHistoryAsync(commitReq, ct);
    }
}
