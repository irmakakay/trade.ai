namespace QuantCore.Agents.Execution;

public sealed record ExecutionOrderRequest(
    Guid ClientOrderId,
    string Symbol,
    string Side,          // "buy" | "sell"
    decimal Quantity,
    decimal ReferencePrice,
    bool IsPromotedModel,
    int ReplicaIndex = 1,
    decimal ModelConfidence = 0m,
    decimal ExpectedEdgeBps = 0m,
    string OrderIntent = "ENTRY", // "ENTRY" | "TAKE_PROFIT" | "STOP_LOSS"
    string ProfileKey = "UNKNOWN",
    bool IsSyntheticMarketData = false
);

public sealed record ExecutionOrderResult(
    bool Accepted,
    string Provider,
    string Mode,          // "SIMULATED" | "DRY_RUN" | "LIVE"
    string? VenueOrderId,
    string Message,
    decimal? ExecutedQuantity = null
);

public interface IOrderExecutionGateway
{
    string ProviderName { get; }
    Task<ExecutionOrderResult> SubmitOrderAsync(ExecutionOrderRequest request, CancellationToken ct);
}
