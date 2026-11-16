using System.Text.Json.Serialization;

namespace QuantCore.Contracts.Domain;

public sealed record ExecutedMoveRecord(
    [property: JsonPropertyName("symbol")] string Symbol,
    [property: JsonPropertyName("action")] string Action,
    [property: JsonPropertyName("quantity")] decimal Quantity,
    [property: JsonPropertyName("fill_price")] decimal FillPrice,
    [property: JsonPropertyName("fee_usdt")] decimal FeeUsdt,
    [property: JsonPropertyName("timestamp_ms")] long TimestampMs
);

public sealed record EpisodeCommitRequest(
    [property: JsonPropertyName("run_id")] Guid RunId,
    [property: JsonPropertyName("pool_instance_id")] Guid PoolInstanceId,
    [property: JsonPropertyName("identity_id")] Guid IdentityId,
    [property: JsonPropertyName("actor_type")] string ActorType,
    [property: JsonPropertyName("profile_key")] string ProfileKey,
    [property: JsonPropertyName("replica_index")] int ReplicaIndex,
    [property: JsonPropertyName("jitter_delta_json")] string JitterDeltaJson,
    [property: JsonPropertyName("executed_moves")] IReadOnlyList<ExecutedMoveRecord> ExecutedMoves,
    [property: JsonPropertyName("realized_pnl_usdt")] decimal RealizedPnlUsdt,
    [property: JsonPropertyName("max_drawdown_pct")] decimal MaxDrawdownPct,
    [property: JsonPropertyName("sharpe_estimate")] decimal SharpeEstimate,
    [property: JsonPropertyName("liquidate_and_release_slices")] bool LiquidateAndReleaseSlices
);

public sealed record EpisodeCommitResponse(
    [property: JsonPropertyName("committed")] bool Committed,
    [property: JsonPropertyName("run_id")] Guid RunId,
    [property: JsonPropertyName("slices_released")] int SlicesReleased,
    [property: JsonPropertyName("recalculation_triggered")] bool RecalculationTriggered
);

public sealed record EpisodeResetCommand(
    [property: JsonPropertyName("profile_key")] string? ProfileKey,
    [property: JsonPropertyName("reason")] string Reason,
    [property: JsonPropertyName("issued_by")] string IssuedBy
);
