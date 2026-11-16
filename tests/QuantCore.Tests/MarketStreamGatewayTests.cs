using QuantCore.Api.Services;
using QuantCore.Contracts.Domain;
using Xunit;

namespace QuantCore.Tests;

public sealed class MarketStreamGatewayTests
{
    private static LiveStreamFrame Frame(string type) => new(type, "ALL", 0m, null, null, 1L);

    [Fact]
    public void PublishFrame_Delivers_To_Every_Subscriber()
    {
        var gateway = new MarketStreamGateway();
        var (dashboard, dashboardSub) = gateway.Subscribe();
        var (agent, agentSub) = gateway.Subscribe();
        using var _ = dashboardSub;
        using var __ = agentSub;

        gateway.PublishFrame(Frame("FORCE_EPISODE_RESET"));

        Assert.True(dashboard.TryRead(out var d));
        Assert.True(agent.TryRead(out var a));
        Assert.Equal("FORCE_EPISODE_RESET", d.EventType);
        Assert.Equal("FORCE_EPISODE_RESET", a.EventType);
    }

    [Fact]
    public void Disposed_Subscription_Stops_Receiving()
    {
        var gateway = new MarketStreamGateway();
        var (reader, subscription) = gateway.Subscribe();

        subscription.Dispose();
        gateway.PublishFrame(Frame("MARKET_TICK"));

        Assert.False(reader.TryRead(out _));
    }

    [Fact]
    public void Slow_Subscriber_Drops_Oldest_Frames_Instead_Of_Growing()
    {
        var gateway = new MarketStreamGateway();
        var (reader, subscription) = gateway.Subscribe();
        using var _ = subscription;

        for (var i = 0; i < 2000; i++)
        {
            gateway.PublishFrame(Frame("MARKET_TICK") with { TimestampMs = i });
        }

        var count = 0;
        long first = -1;
        while (reader.TryRead(out var f))
        {
            if (count++ == 0) first = f.TimestampMs;
        }

        Assert.Equal(1024, count);
        Assert.Equal(2000 - 1024, first);
    }
}
