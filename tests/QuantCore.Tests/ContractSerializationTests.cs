using System.Text.Json;
using QuantCore.Contracts.Domain;
using QuantCore.Contracts.Messaging;
using Xunit;

namespace QuantCore.Tests;

public sealed class ContractSerializationTests
{
    private static T RoundTrip<T>(T value, out string json) where T : notnull
    {
        json = JsonSerializer.Serialize(value);
        var copy = JsonSerializer.Deserialize<T>(json);
        Assert.NotNull(copy);
        Assert.False(string.IsNullOrEmpty(value.ToString()));
        _ = value.GetHashCode();
        return copy;
    }

    [Fact]
    public void InputTaskMessage_RoundTrips()
    {
        var msg = new InputTaskMessage(Guid.NewGuid(), TaskCommandType.FORECAST_MOVES, "P", 0.5m, 2,
            new[] { "BTCUSDT" }, DateTimeOffset.UnixEpoch);
        var copy = RoundTrip(msg, out var json);
        Assert.Contains("\"submitted_at_utc\":", json);
        Assert.Equal(msg.JobId, copy.JobId);
        Assert.Equal(msg.Command, copy.Command);
        Assert.Equal(msg.ProfileKey, copy.ProfileKey);
        Assert.Equal(msg.RiskDialR, copy.RiskDialR);
        Assert.Equal(msg.ReplicationFactor, copy.ReplicationFactor);
        Assert.Equal(msg.CandidateSymbols, copy.CandidateSymbols);
        Assert.Equal(msg.SubmittedAtUtc, copy.SubmittedAtUtc);
        Assert.Equal(msg with { ProfileKey = "Q" }, msg with { ProfileKey = "Q" });
    }

    [Fact]
    public void OutputStatusMessage_RoundTrips_With_String_Enum()
    {
        var msg = new OutputStatusMessage(Guid.NewGuid(), QueueJobState.SUCCEEDED, 100m, 0.9m, "{}", null,
            DateTimeOffset.UnixEpoch);
        var copy = RoundTrip(msg, out var json);
        Assert.Contains("\"status\":\"SUCCEEDED\"", json);
        Assert.Contains("\"result_payload\":\"{}\"", json);
        Assert.Equal(msg.JobId, copy.JobId);
        Assert.Equal(msg.Status, copy.Status);
        Assert.Equal(msg.ProgressPct, copy.ProgressPct);
        Assert.Equal(msg.ConfidenceScore, copy.ConfidenceScore);
        Assert.Equal(msg.ResultPayloadJson, copy.ResultPayloadJson);
        Assert.Null(copy.ErrorMessage);
        Assert.Equal(msg.UpdatedAtUtc, copy.UpdatedAtUtc);
        Assert.Equal(msg, msg with { });
    }

    [Fact]
    public void PoolCheckoutRequest_RoundTrips()
    {
        var req = new PoolCheckoutRequest(Guid.NewGuid(), "AGGRESSIVE_BREAKOUT");
        var copy = RoundTrip(req, out var json);
        Assert.Contains("\"agent_id\":", json);
        Assert.Equal(req.AgentId, copy.AgentId);
        Assert.Equal(req.ProfileKey, copy.ProfileKey);
        Assert.Equal(req, copy);
    }

    [Fact]
    public void PoolSlotDto_RoundTrips()
    {
        var dto = new PoolSlotDto(Guid.NewGuid(), "P", 1, 0.7m, "{}", "{\"a\":1}", "[\"BTCUSDT\"]");
        var copy = RoundTrip(dto, out var json);
        Assert.Contains("\"pool_instance_id\":", json);
        Assert.Equal(dto.PoolInstanceId, copy.PoolInstanceId);
        Assert.Equal(dto.ProfileKey, copy.ProfileKey);
        Assert.Equal(dto.ReplicaIndex, copy.ReplicaIndex);
        Assert.Equal(dto.RiskDialR, copy.RiskDialR);
        Assert.Equal(dto.JitterDeltaJson, copy.JitterDeltaJson);
        Assert.Equal(dto.StrategyPayloadJson, copy.StrategyPayloadJson);
        Assert.Equal(dto.CandidateSymbolsJson, copy.CandidateSymbolsJson);
        Assert.Equal(dto, copy);
    }

    [Fact]
    public void ShareSliceClaimRequest_RoundTrips()
    {
        var req = new ShareSliceClaimRequest(Guid.NewGuid(), Guid.NewGuid(), "SOLUSDT", 0.4m, "LONG_ACCUMULATING");
        var copy = RoundTrip(req, out var json);
        Assert.Contains("\"requested_fraction_pct\":0.4", json);
        Assert.Equal(req.AgentId, copy.AgentId);
        Assert.Equal(req.StrategyId, copy.StrategyId);
        Assert.Equal(req.DirectionalBias, copy.DirectionalBias);
        Assert.Equal(req, copy);
    }

    [Fact]
    public void ShareSliceClaimResult_RoundTrips()
    {
        var res = new ShareSliceClaimResult(true, "SOLUSDT", 1.5m, 8.5m, "ok");
        var copy = RoundTrip(res, out var json);
        Assert.Contains("\"remaining_unallocated\":8.5", json);
        Assert.True(copy.Claimed);
        Assert.Equal(res.Symbol, copy.Symbol);
        Assert.Equal(res.ReservedQuantity, copy.ReservedQuantity);
        Assert.Equal(res.RemainingUnallocated, copy.RemainingUnallocated);
        Assert.Equal(res.Reason, copy.Reason);
        Assert.Equal(res, copy);
    }

    [Fact]
    public void LiveStreamFrame_RoundTrips_With_Nullable_Fields()
    {
        var frame = new LiveStreamFrame("TICK", "BTCUSDT", 65000.5m, null, null, 1700000000000L);
        var copy = RoundTrip(frame, out var json);
        Assert.Contains("\"timestamp_ms\":1700000000000", json);
        Assert.Equal(frame.EventType, copy.EventType);
        Assert.Equal(frame.Symbol, copy.Symbol);
        Assert.Equal(frame.Price, copy.Price);
        Assert.Null(copy.AgentId);
        Assert.Null(copy.Action);
        Assert.Equal(frame.TimestampMs, copy.TimestampMs);
        Assert.Equal(frame, copy);
        Assert.True(frame == copy);
    }
}
