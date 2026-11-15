using System.Text.Json.Serialization;

namespace QuantCore.Contracts.Domain;

public sealed record PoolCheckoutRequest(
    [property: JsonPropertyName("agent_id")] Guid AgentId,
    [property: JsonPropertyName("profile_key")] string ProfileKey
);

public sealed record PoolSlotDto(
    [property: JsonPropertyName("pool_instance_id")] Guid PoolInstanceId,
    [property: JsonPropertyName("profile_key")] string ProfileKey,
    [property: JsonPropertyName("replica_index")] int ReplicaIndex,
    [property: JsonPropertyName("risk_dial_r")] decimal RiskDialR,
    [property: JsonPropertyName("jitter_delta_json")] string JitterDeltaJson,
    [property: JsonPropertyName("strategy_payload_json")] string StrategyPayloadJson,
    [property: JsonPropertyName("candidate_symbols_json")] string CandidateSymbolsJson
);

public sealed record ShareSliceClaimRequest(
    [property: JsonPropertyName("agent_id")] Guid AgentId,
    [property: JsonPropertyName("strategy_id")] Guid StrategyId,
    [property: JsonPropertyName("symbol")] string Symbol,
    [property: JsonPropertyName("requested_fraction_pct")] decimal RequestedFractionPct,
    [property: JsonPropertyName("directional_bias")] string DirectionalBias
);

public sealed record ShareSliceClaimResult(
    [property: JsonPropertyName("claimed")] bool Claimed,
    [property: JsonPropertyName("symbol")] string Symbol,
    [property: JsonPropertyName("reserved_quantity")] decimal ReservedQuantity,
    [property: JsonPropertyName("remaining_unallocated")] decimal RemainingUnallocated,
    [property: JsonPropertyName("reason")] string Reason
);

public readonly record struct LiveStreamFrame(
    [property: JsonPropertyName("event_type")] string EventType,
    [property: JsonPropertyName("symbol")] string Symbol,
    [property: JsonPropertyName("price")] decimal Price,
    [property: JsonPropertyName("agent_id")] Guid? AgentId,
    [property: JsonPropertyName("action")] string? Action,
    [property: JsonPropertyName("timestamp_ms")] long TimestampMs
);
