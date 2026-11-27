using System.Net.Http;
using QuantCore.Agents.Execution.Auth;
using QuantCore.Agents.Execution.Middleware;

namespace QuantCore.Agents.Execution;

public static class ExecutionServiceCollectionExtensions
{
    public static IServiceCollection AddQuantExecutionInfrastructure(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        string gatewayMode = (configuration["EXECUTION_GATEWAY"] ?? "SIMULATED")
            .Trim()
            .ToUpperInvariant();

        bool dryRun = configuration.GetValue<bool>("REVX_DRY_RUN", true);
        string authProvider = (configuration["REVX_AUTH_PROVIDER"] ?? string.Empty)
            .Trim()
            .ToUpperInvariant();

        if (string.IsNullOrEmpty(authProvider))
        {
            authProvider = (gatewayMode == "REVOLUT_X" && !dryRun) ? "ED25519" : "FAKE";
        }

        if (authProvider == "ED25519")
        {
            services.AddSingleton<RevxAuthenticatorBase, RevxEd25519Authenticator>();
        }
        else
        {
            services.AddSingleton<RevxAuthenticatorBase, FakeRevxAuthenticator>();
        }

        services.AddSingleton<IRevxAuthenticator>(sp => sp.GetRequiredService<RevxAuthenticatorBase>());
        services.AddTransient<RevxSigningDelegatingHandler>();
        services.AddSingleton<SimulatedExecutionGateway>();

        if (gatewayMode == "REVOLUT_X")
        {
            string revxBaseUrl = configuration["REVX_API_BASE_URL"] ?? "https://revx.revolut.com";
            services.AddHttpClient<RevolutXExecutionGateway>(client =>
            {
                client.BaseAddress = new Uri(revxBaseUrl);
            })
            .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
            {
                PooledConnectionLifetime = TimeSpan.FromMinutes(2)
            })
            .SetHandlerLifetime(Timeout.InfiniteTimeSpan)
            .AddHttpMessageHandler<RevxSigningDelegatingHandler>();

            services.AddSingleton<PromotedRoutingExecutionGateway>(sp =>
                new PromotedRoutingExecutionGateway(
                    sp.GetRequiredService<SimulatedExecutionGateway>(),
                    sp.GetRequiredService<RevolutXExecutionGateway>(),
                    sp.GetRequiredService<IConfiguration>(),
                    sp.GetRequiredService<ILogger<PromotedRoutingExecutionGateway>>()));

            services.AddSingleton<IOrderExecutionGateway>(sp =>
                new TelemetryExecutionGateway(
                    sp.GetRequiredService<PromotedRoutingExecutionGateway>(),
                    sp.GetRequiredService<IConfiguration>(),
                    sp.GetRequiredService<ILogger<TelemetryExecutionGateway>>()));
        }
        else
        {
            services.AddSingleton<IOrderExecutionGateway>(sp =>
                new TelemetryExecutionGateway(
                    sp.GetRequiredService<SimulatedExecutionGateway>(),
                    sp.GetRequiredService<IConfiguration>(),
                    sp.GetRequiredService<ILogger<TelemetryExecutionGateway>>()));
        }

        return services;
    }
}
