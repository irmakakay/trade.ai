using System.Text.Json.Serialization;

namespace QuantCore.Contracts.Messaging;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum TaskCommandType
{
    TRAIN_HISTORICAL,
    RECALCULATE_POOL,
    FORECAST_MOVES
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum QueueJobState
{
    STARTING,
    PROCESSING,
    SUCCEEDED,
    FAILED
}

public sealed record InputTaskMessage(
    [property: JsonPropertyName("job_id")] Guid JobId,
    [property: JsonPropertyName("command")] TaskCommandType Command,
    [property: JsonPropertyName("profile_key")] string ProfileKey,
    [property: JsonPropertyName("risk_dial_r")] decimal RiskDialR,
    [property: JsonPropertyName("replication_factor")] int ReplicationFactor,
    [property: JsonPropertyName("candidate_symbols")] IReadOnlyList<string> CandidateSymbols,
    [property: JsonPropertyName("submitted_at_utc")] DateTimeOffset SubmittedAtUtc
);

public sealed record OutputStatusMessage(
    [property: JsonPropertyName("job_id")] Guid JobId,
    [property: JsonPropertyName("status")] QueueJobState Status,
    [property: JsonPropertyName("progress_pct")] decimal ProgressPct,
    [property: JsonPropertyName("confidence_score")] decimal ConfidenceScore,
    [property: JsonPropertyName("result_payload")] string? ResultPayloadJson,
    [property: JsonPropertyName("error_message")] string? ErrorMessage,
    [property: JsonPropertyName("updated_at_utc")] DateTimeOffset UpdatedAtUtc
);
