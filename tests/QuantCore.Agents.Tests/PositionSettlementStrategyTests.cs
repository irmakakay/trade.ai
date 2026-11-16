using NSubstitute;
using QuantCore.Agents.Client;
using QuantCore.Agents.Settlement;
using QuantCore.Contracts.Domain;
using Xunit;

namespace QuantCore.Agents.Tests;

public sealed class PositionSettlementStrategyTests
{
    private static ActiveAgentContext CreateSampleContext() => new(
        RunId: Guid.NewGuid(),
        PoolInstanceId: Guid.NewGuid(),
        AgentId: Guid.NewGuid(),
        ActorType: "AGENT",
        ProfileKey: "AGGRESSIVE_BREAKOUT",
        ReplicaIndex: 2,
        JitterDeltaJson: "{\"entry_threshold\":0.02}",
        ExecutedMoves: new[]
        {
            new ExecutedMoveRecord("SOLUSDT", "BUY_SLICE_CLAIM", 10m, 150m, 1.5m, 1700000000000L)
        },
        RealizedPnlUsdt: 40.0m,
        MaxDrawdownPct: 0.03m,
        SharpeEstimate: 1.8m,
        OpenSymbolQuantities: new Dictionary<string, decimal> { ["SOLUSDT"] = 10m },
        LatestMarketPrices: new Dictionary<string, decimal> { ["SOLUSDT"] = 160m }
    );

    [Fact]
    public async Task LiquidateAndReleaseStrategy_Appends_SellLiquidateMove_And_Sets_ReleaseFlag_True()
    {
        var api = Substitute.For<IQuantApiClient>();
        EpisodeCommitRequest? captured = null;
        api.CommitEpisodeHistoryAsync(Arg.Do<EpisodeCommitRequest>(r => captured = r), Arg.Any<CancellationToken>())
           .Returns(new EpisodeCommitResponse(true, Guid.NewGuid(), 1, true));

        IPositionSettlementStrategy strategy = new LiquidateAndReleaseStrategy(api);
        var ctx = CreateSampleContext();

        var res = await strategy.SettleEpisodeAsync(ctx, CancellationToken.None);

        Assert.NotNull(res);
        Assert.NotNull(captured);
        Assert.True(captured!.LiquidateAndReleaseSlices);
        Assert.Equal(2, captured.ExecutedMoves.Count);
        Assert.Equal("SELL_LIQUIDATE_EOP", captured.ExecutedMoves[1].Action);
        // 10 SOL * $160 = $1600 gross -> 0.10% fee = $1.60 deducted from 40.0m realized PnL
        Assert.Equal(38.40m, captured.RealizedPnlUsdt);
    }

    [Fact]
    public async Task CarryPositionsStrategy_Preserves_Open_Positions_And_Sets_ReleaseFlag_False()
    {
        var api = Substitute.For<IQuantApiClient>();
        EpisodeCommitRequest? captured = null;
        api.CommitEpisodeHistoryAsync(Arg.Do<EpisodeCommitRequest>(r => captured = r), Arg.Any<CancellationToken>())
           .Returns(new EpisodeCommitResponse(true, Guid.NewGuid(), 0, false));

        IPositionSettlementStrategy strategy = new CarryPositionsStrategy(api);
        var ctx = CreateSampleContext();

        var res = await strategy.SettleEpisodeAsync(ctx, CancellationToken.None);

        Assert.NotNull(res);
        Assert.NotNull(captured);
        Assert.False(captured!.LiquidateAndReleaseSlices);
        Assert.Single(captured.ExecutedMoves);
        Assert.Equal(40.0m, captured.RealizedPnlUsdt);
    }
}
