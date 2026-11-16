using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;
using QuantCore.Agents.Client;
using QuantCore.Agents.Services;
using QuantCore.Agents.Settlement;
using QuantCore.Contracts.Domain;
using Xunit;

namespace QuantCore.Agents.Tests;

public sealed class EpisodeCommandWatcherTests
{
    [Fact]
    public void TriggerLocalReset_Cancels_Active_Episode_Token_Immediately()
    {
        var cfg = new ConfigurationBuilder().Build();
        var watcher = new EpisodeCommandWatcher(cfg, NullLogger<EpisodeCommandWatcher>.Instance);

        CancellationToken tokenBefore = watcher.CurrentEpisodeResetToken;
        Assert.False(tokenBefore.IsCancellationRequested);

        watcher.TriggerLocalReset("OPERATOR_FORCE_RESET");

        Assert.True(tokenBefore.IsCancellationRequested);
        Assert.False(watcher.CurrentEpisodeResetToken.IsCancellationRequested);
    }

    [Fact]
    public async Task AgentSwarm_Interrupts_TickQuota_When_Precedence_Reset_Fires()
    {
        var api = Substitute.For<IQuantApiClient>();
        api.ClaimSymbolSliceAsync(Arg.Any<ShareSliceClaimRequest>(), Arg.Any<CancellationToken>())
           .Returns(new ShareSliceClaimResult(true, "SOLUSDT", 5m, 40m, "OK"));

        var settlement = Substitute.For<IPositionSettlementStrategy>();
        settlement.SettleEpisodeAsync(Arg.Any<ActiveAgentContext>(), Arg.Any<CancellationToken>())
                  .Returns(new EpisodeCommitResponse(true, Guid.NewGuid(), 1, false));

        var cfg = new ConfigurationBuilder().Build();
        var watcher = new EpisodeCommandWatcher(cfg, NullLogger<EpisodeCommandWatcher>.Instance);
        var swarm = new AgentSwarmHostedService(
            api, settlement, watcher, cfg, NullLogger<AgentSwarmHostedService>.Instance);

        var slot = new PoolSlotDto(
            Guid.NewGuid(), "AGGRESSIVE_BREAKOUT", 1, 0.85m, "{}", "{}", "[\"SOLUSDT\"]");

        // Trigger precedence reset after 80ms even though maxTicks=10,000 and maxSeconds=60
        _ = Task.Run(async () =>
        {
            await Task.Delay(80);
            watcher.TriggerLocalReset("TEST_PREEMPTIVE_RESET");
        });

        var result = await swarm.RunSingleEpisodeAsync(
            Guid.NewGuid(), slot, maxTicks: 10000, maxSeconds: 60, CancellationToken.None);

        Assert.NotNull(result);
        Assert.True(result!.Committed);
        await settlement.Received(1).SettleEpisodeAsync(Arg.Any<ActiveAgentContext>(), Arg.Any<CancellationToken>());
    }
}
