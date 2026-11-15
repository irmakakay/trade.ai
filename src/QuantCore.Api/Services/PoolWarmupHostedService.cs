using QuantCore.Api.Messaging;
using QuantCore.Contracts.Messaging;

namespace QuantCore.Api.Services;

public sealed class PoolWarmupHostedService : IHostedService
{
    private readonly IRabbitMqQueueService _queueService;
    private readonly IConfiguration _config;
    public bool IsWarmupDispatched { get; private set; }

    public PoolWarmupHostedService(IRabbitMqQueueService queueService, IConfiguration config)
    {
        _queueService = queueService;
        _config = config;
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        int kFactor = _config.GetValue<int>("POOL_REPLICATION_FACTOR", 3);
        var defaultProfiles = new (string Key, decimal RiskR)[]
        {
            ("CAREFUL_MEAN_REVERSION", 0.20m),
            ("BALANCED_SWING", 0.50m),
            ("AGGRESSIVE_BREAKOUT", 0.85m)
        };

        foreach (var profile in defaultProfiles)
        {
            var warmupJob = new InputTaskMessage(
                Guid.NewGuid(),
                TaskCommandType.RECALCULATE_POOL,
                profile.Key,
                profile.RiskR,
                kFactor,
                new[] { "BTCUSDT", "ETHUSDT", "SOLUSDT" },
                DateTimeOffset.UtcNow
            );
            _queueService.SubmitTaskToInputQueue(warmupJob);
        }

        IsWarmupDispatched = true;
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
