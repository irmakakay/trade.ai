namespace QuantCore.Agents.Execution;

public sealed record ExecutionOrderRequest(
    Guid ClientOrderId,
    string Symbol,
    string Side,          // "buy" | "sell"
    decimal Quantity,
    decimal ReferencePrice,
    bool IsPromotedModel
);

public sealed record ExecutionOrderResult(
    bool Accepted,
    string Provider,
    string Mode,          // "SIMULATED" | "DRY_RUN" | "LIVE"
    string? VenueOrderId,
    string Message
);

public interface IOrderExecutionGateway
{
    string ProviderName { get; }
    Task<ExecutionOrderResult> SubmitOrderAsync(ExecutionOrderRequest request, CancellationToken ct);
}
