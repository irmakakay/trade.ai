using System.Text.Json;
using QuantCore.Contracts.Domain;
using QuantCore.Contracts.Messaging;
using Xunit;

namespace QuantCore.Tests;

public sealed class ContractParityTests
{
    [Fact]
    public void InputTaskMessage_Serializes_To_SnakeCase_Matching_Python_Pydantic()
    {
        var msg = new InputTaskMessage(
            Guid.Parse("11111111-1111-1111-1111-111111111111"),
            TaskCommandType.RECALCULATE_POOL,
            "AGGRESSIVE_BREAKOUT",
            0.85m,
            3,
            new[] { "BTCUSDT", "SOLUSDT" },
            DateTimeOffset.UtcNow
        );

        string json = JsonSerializer.Serialize(msg);
        Assert.Contains("\"job_id\":", json);
        Assert.Contains("\"command\":\"RECALCULATE_POOL\"", json);
        Assert.Contains("\"risk_dial_r\":0.85", json);
        Assert.Contains("\"replication_factor\":3", json);
    }

    [Fact]
    public void ShareSliceClaimRequest_Validates_Fields()
    {
        var req = new ShareSliceClaimRequest(Guid.NewGuid(), Guid.NewGuid(), "SOLUSDT", 0.40m, "LONG_ACCUMULATING");
        Assert.Equal("SOLUSDT", req.Symbol);
        Assert.Equal(0.40m, req.RequestedFractionPct);
    }
}
