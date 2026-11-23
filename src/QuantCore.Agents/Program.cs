using QuantCore.Agents.Execution;
using QuantCore.Agents.Cli;
using QuantCore.Agents.Client;
using QuantCore.Agents.Services;
using QuantCore.Agents.Settlement;

var builder = Host.CreateApplicationBuilder(args);

string apiBaseUrl = builder.Configuration["QUANT_API_URL"] ?? "http://localhost:8080";
builder.Services.AddHttpClient<IQuantApiClient, QuantApiClient>(client =>
{
    client.BaseAddress = new Uri(apiBaseUrl);
});

// Inject IPositionSettlementStrategy strictly via deployment environment variable
string settlementMode = (builder.Configuration["EPISODE_SETTLEMENT_MODE"] ?? "LIQUIDATE_AND_RELEASE")
    .Trim()
    .ToUpperInvariant();

if (settlementMode == "CARRY_POSITIONS")
{
    builder.Services.AddSingleton<IPositionSettlementStrategy, CarryPositionsStrategy>();
}
else
{
    builder.Services.AddSingleton<IPositionSettlementStrategy, LiquidateAndReleaseStrategy>();
}


// Execution gateway defaults to SIMULATED so existing swarm execution is completely unbroken
string executionGatewayMode = (builder.Configuration["EXECUTION_GATEWAY"] ?? "SIMULATED")
    .Trim()
    .ToUpperInvariant();

if (executionGatewayMode == "REVOLUT_X")
{
    string revxBaseUrl = builder.Configuration["REVX_API_BASE_URL"] ?? "https://revx.revolut.com";
    builder.Services.AddHttpClient<IOrderExecutionGateway, RevolutXExecutionGateway>(client =>
    {
        client.BaseAddress = new Uri(revxBaseUrl);
    });
}
else
{
    builder.Services.AddSingleton<IOrderExecutionGateway, SimulatedExecutionGateway>();
}

// Parse --mode switch (default: agent)
string executionMode = "agent";
for (int i = 0; i < args.Length; i++)
{
    if (args[i].Equals("--mode", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
    {
        executionMode = args[i + 1].Trim().ToLowerInvariant();
    }
}

if (executionMode == "cli")
{
    builder.Services.AddSingleton<InteractiveCliRunner>();
    using var host = builder.Build();
    var cli = host.Services.GetRequiredService<InteractiveCliRunner>();
    await cli.RunInteractiveLoopAsync(CancellationToken.None);
}
else
{
    builder.Services.AddSingleton<EpisodeCommandWatcher>();
    builder.Services.AddSingleton<IEpisodeCommandWatcher>(sp => sp.GetRequiredService<EpisodeCommandWatcher>());
    builder.Services.AddHostedService(sp => sp.GetRequiredService<EpisodeCommandWatcher>());
    builder.Services.AddHostedService<AgentSwarmHostedService>();

    using var host = builder.Build();
    await host.RunAsync();
}
