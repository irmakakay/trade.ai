using System.Data;
using Npgsql;
using QuantCore.Api.Messaging;
using QuantCore.Api.Repositories;
using QuantCore.Api.Services;
using QuantCore.Contracts.Domain;
using QuantCore.Contracts.Messaging;
using RabbitMQ.Client;
using QuantCore.Api.Endpoints;

var builder = WebApplication.CreateBuilder(args);

string pgConnStr = builder.Configuration["POSTGRES_CONNECTION"]
    ?? "Host=localhost;Port=5432;Database=quantcore;Username=quant;Password=quant_secret";

builder.Services.AddSingleton<Func<IDbConnection>>(_ => () => new NpgsqlConnection(pgConnStr));
builder.Services.AddSingleton<IConnection>(_ =>
{
    var factory = new ConnectionFactory
    {
        HostName = builder.Configuration["RABBITMQ_HOST"] ?? "localhost",
        Port = int.Parse(builder.Configuration["RABBITMQ_PORT"] ?? "5672")
    };
    return factory.CreateConnection();
});

builder.Services.AddSingleton<IRabbitMqQueueService, RabbitMqQueueService>();
builder.Services.AddSingleton<IStrategyPoolRepository, StrategyPoolRepository>();
builder.Services.AddSingleton<IInventoryLockRepository, InventoryLockRepository>();
builder.Services.AddSingleton<MarketStreamGateway>();
builder.Services.AddHostedService<PoolWarmupHostedService>();

var app = builder.Build();

app.UseDefaultFiles();
app.UseStaticFiles();
app.UseWebSockets();

app.MapGet("/health/live", () => Results.Ok(new { status = "ALIVE" }));
app.MapGet("/health/ready", async (IStrategyPoolRepository poolRepo, CancellationToken ct) =>
{
    int available = await poolRepo.GetAvailablePoolCountAsync(ct);
    return available > 0
        ? Results.Ok(new { status = "READY", available_pool_slots = available })
        : Results.StatusCode(503);
});

app.MapGet("/metrics", async (IStrategyPoolRepository poolRepo, CancellationToken ct) =>
{
    int slots = await poolRepo.GetAvailablePoolCountAsync(ct);
    return Results.Text($"# HELP quantcore_pool_available_slots Available pre-calculated strategy slots\n# TYPE quantcore_pool_available_slots gauge\nquantcore_pool_available_slots {slots}\n", "text/plain");
});

app.MapPost("/api/v1/tasks", (InputTaskMessage task, IRabbitMqQueueService mq) =>
{
    mq.SubmitTaskToInputQueue(task);
    return Results.Accepted($"/api/v1/tasks/status", new { task.JobId, status = "STARTING" });
});

app.MapGet("/api/v1/tasks/status", (IRabbitMqQueueService mq) =>
{
    var status = mq.PeekOutputQueueStatus();
    return status is not null ? Results.Ok(status) : Results.NotFound(new { message = "OUTPUT_QUEUE_EMPTY" });
});

app.MapPost("/api/v1/pool/checkout", async (PoolCheckoutRequest req, IStrategyPoolRepository repo, MarketStreamGateway stream, CancellationToken ct) =>
{
    var slot = await repo.CheckoutNextAvailableSlotAsync(req.AgentId, req.profile_key_normalized(), ct);
    if (slot is null)
    {
        return Results.Conflict(new { error = "POOL_EXHAUSTED_FOR_PROFILE", req.ProfileKey });
    }
    stream.PublishFrame(new LiveStreamFrame("AGENT_CHECKOUT", slot.ProfileKey, slot.RiskDialR, req.AgentId, $"REPLICA_{slot.ReplicaIndex}", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
    return Results.Ok(slot);
});

app.MapPost("/api/v1/inventory/claim-slice", async (ShareSliceClaimRequest req, IInventoryLockRepository repo, MarketStreamGateway stream, IConfiguration cfg, CancellationToken ct) =>
{
    int ttl = cfg.GetValue<int>("LOCK_TTL_SECONDS", 5);
    var res = await repo.ClaimSymbolSliceAtomicAsync(req, ttl, ct);
    if (!res.Claimed)
    {
        return Results.Conflict(res);
    }
    stream.PublishFrame(new LiveStreamFrame("AGENT_SLICE_LOCK", req.Symbol, res.ReservedQuantity, req.AgentId, req.DirectionalBias, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
    return Results.Ok(res);
});

app.Map("/api/v1/stream/live", async (HttpContext ctx, MarketStreamGateway stream, CancellationToken ct) =>
{
    if (!ctx.WebSockets.IsWebSocketRequest)
    {
        ctx.Response.StatusCode = 400;
        return;
    }
    using var ws = await ctx.WebSockets.AcceptWebSocketAsync();
    await stream.HandleDashboardClientAsync(ws, ct);
});

app.MapAgentEpisodeEndpoints();

app.Run();

internal static class RequestExtensions
{
    public static string profile_key_normalized(this PoolCheckoutRequest req) => req.ProfileKey.Trim().ToUpperInvariant();
}
