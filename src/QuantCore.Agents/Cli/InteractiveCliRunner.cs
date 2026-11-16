using QuantCore.Agents.Client;
using QuantCore.Agents.Settlement;
using QuantCore.Contracts.Domain;
using QuantCore.Contracts.Messaging;
using Spectre.Console;

namespace QuantCore.Agents.Cli;

public sealed class InteractiveCliRunner
{
    private readonly IQuantApiClient _apiClient;
    private readonly IPositionSettlementStrategy _settlementStrategy;

    public InteractiveCliRunner(IQuantApiClient apiClient, IPositionSettlementStrategy settlementStrategy)
    {
        _apiClient = apiClient;
        _settlementStrategy = settlementStrategy;
    }

    public async Task RunInteractiveLoopAsync(CancellationToken ct)
    {
        Guid operatorId = Guid.NewGuid();
        AnsiConsole.MarkupLine("[bold cyan]QuantCore Interactive CLI Operator (--mode cli)[/]");
        AnsiConsole.MarkupLine($"[grey]Operator ID: {operatorId} | Active Settlement Strategy: {_settlementStrategy.StrategyName}[/]");

        while (!ct.IsCancellationRequested)
        {
            var choice = AnsiConsole.Prompt(
                new SelectionPrompt<string>()
                    .Title("[yellow]Select Operator Action:[/]")
                    .AddChoices(
                        "1. Checkout Strategy Pool Slot (First-Wins)",
                        "2. Claim Symbol Share Slice (Atomic Mutex)",
                        "3. Broadcast Precedence FORCE_EPISODE_RESET to All Agents",
                        "4. Trigger NN Pool Recalculation Job",
                        "5. Exit CLI"));

            if (choice.StartsWith("1."))
            {
                string profile = AnsiConsole.Ask<string>("Profile Key:", "AGGRESSIVE_BREAKOUT");
                var slot = await _apiClient.CheckoutStrategySlotAsync(operatorId, profile, ct);
                if (slot is null)
                    AnsiConsole.MarkupLine("[red]409 Conflict: Strategy pool exhausted for profile.[/]");
                else
                    AnsiConsole.MarkupLine($"[green]Checked Out Replica #{slot.ReplicaIndex}[/] | Jitter={slot.JitterDeltaJson}");
            }
            else if (choice.StartsWith("2."))
            {
                string sym = AnsiConsole.Ask<string>("Symbol:", "SOLUSDT");
                decimal pct = AnsiConsole.Ask<decimal>("Fraction (0.01 - 1.0):", 0.25m);
                var res = await _apiClient.ClaimSymbolSliceAsync(
                    new ShareSliceClaimRequest(operatorId, Guid.NewGuid(), sym, pct, "LONG_CLI_MANUAL"), ct);
                AnsiConsole.MarkupLine(res is { Claimed: true }
                    ? $"[green]Claimed {res.ReservedQuantity} {sym}[/] (Remaining: {res.RemainingUnallocated})"
                    : $"[red]Rejected:[/] {res?.Reason}");
            }
            else if (choice.StartsWith("3."))
            {
                bool ok = await _apiClient.BroadcastForceResetAsync(
                    new EpisodeResetCommand(null, "CLI_OPERATOR_PRECEDENCE_RESET", operatorId.ToString()), ct);
                AnsiConsole.MarkupLine(ok
                    ? "[bold green]FORCE_EPISODE_RESET broadcasted to all running agents![/]"
                    : "[red]Failed to broadcast reset.[/]");
            }
            else if (choice.StartsWith("4."))
            {
                string profile = AnsiConsole.Ask<string>("Profile Key:", "AGGRESSIVE_BREAKOUT");
                decimal r = AnsiConsole.Ask<decimal>("Risk Dial r [0.0 - 1.0]:", 0.85m);
                bool ok = await _apiClient.SubmitTaskAsync(new InputTaskMessage(
                    Guid.NewGuid(), TaskCommandType.RECALCULATE_POOL, profile, r, 3,
                    new[] { "BTCUSDT", "ETHUSDT", "SOLUSDT" }, DateTimeOffset.UtcNow), ct);
                AnsiConsole.MarkupLine(ok ? "[green]Recalculation queued on input_queue.[/]" : "[red]Queue submission failed.[/]");
            }
            else
            {
                break;
            }
        }
    }
}
