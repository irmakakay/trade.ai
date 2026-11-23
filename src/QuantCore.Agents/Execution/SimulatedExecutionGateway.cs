namespace QuantCore.Agents.Execution;

public sealed class SimulatedExecutionGateway : IOrderExecutionGateway
{
    public string ProviderName => "SIMULATED";

    public Task<ExecutionOrderResult> SubmitOrderAsync(ExecutionOrderRequest request, CancellationToken ct)
    {
        return Task.FromResult(new ExecutionOrderResult(
            Accepted: true,
            Provider: ProviderName,
            Mode: "SIMULATED",
            VenueOrderId: $"sim-{request.ClientOrderId:N}",
            Message: $"Simulated {request.Side} {request.Quantity} {request.Symbol} @ {request.ReferencePrice}"
        ));
    }
}
