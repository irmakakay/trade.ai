using System.Text.Json;
using QuantCore.Agents.Client;
using QuantCore.Agents.Settlement;
using QuantCore.Contracts.Domain;

namespace QuantCore.Agents.Services;

public sealed class AgentSwarmHostedService : BackgroundService
{
    private readonly IQuantApiClient _apiClient;
    private readonly IPositionSettlementStrategy _settlementStrategy;
    private readonly IEpisodeCommandWatcher _commandWatcher;
    private readonly IConfiguration _config;
    private readonly ILogger<AgentSwarmHostedService> _logger;

    public AgentSwarmHostedService(
        IQuantApiClient apiClient,
        IPositionSettlementStrategy settlementStrategy,
        IEpisodeCommandWatcher commandWatcher,
        IConfiguration config,
        ILogger<AgentSwarmHostedService> logger)
    {
        _apiClient = apiClient;
        _settlementStrategy = settlementStrategy;
        _commandWatcher = commandWatcher;
        _config = config;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        string profileKey = _config["AGENT_PROFILE_KEY"] ?? "AGGRESSIVE_BREAKOUT";
        int maxTicksPerEpisode = _config.GetValue<int>("EPISODE_MAX_TICKS", 100);
        int maxEpisodeSeconds = _config.GetValue<int>("EPISODE_MAX_SECONDS", 300);
        Guid agentId = Guid.NewGuid();

        _logger.LogInformation(
            "[Agent {AgentId}] Booted in --mode agent | Profile={Profile} | Settlement={Settlement}",
            agentId, profileKey, _settlementStrategy.StrategyName);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var slot = await _apiClient.CheckoutStrategySlotAsync(agentId, profileKey, stoppingToken);
                if (slot is null)
                {
                    await Task.Delay(TimeSpan.FromSeconds(3), stoppingToken);
                    continue;
                }

                await RunSingleEpisodeAsync(agentId, slot, maxTicksPerEpisode, maxEpisodeSeconds, stoppingToken);
            }
            catch (HttpRequestException ex)
            {
                // API not ready yet or transient failure: back off instead of crashing the host.
                _logger.LogWarning("[Agent {AgentId}] QuantCore.Api call failed: {Message}", agentId, ex.Message);
                await Task.Delay(TimeSpan.FromSeconds(3), stoppingToken);
            }
        }
    }

    public async Task<EpisodeCommitResponse?> RunSingleEpisodeAsync(
        Guid agentId,
        PoolSlotDto slot,
        int maxTicks,
        int maxSeconds,
        CancellationToken stoppingToken)
    {
        var symbols = JsonSerializer.Deserialize<List<string>>(slot.CandidateSymbolsJson) ?? new List<string> { "SOLUSDT" };
        var openQuantities = new Dictionary<string, decimal>();
        var latestPrices = new Dictionary<string, decimal>();
        var moves = new List<ExecutedMoveRecord>();

        // 1. Iterate ranked symbols & claim First-Wins slice
        foreach (var sym in symbols)
        {
            var claim = await _apiClient.ClaimSymbolSliceAsync(
                new ShareSliceClaimRequest(agentId, slot.PoolInstanceId, sym, 0.25m, "LONG_ACCUMULATING"),
                stoppingToken);

            if (claim is { Claimed: true, ReservedQuantity: > 0m })
            {
                openQuantities[sym] = claim.ReservedQuantity;
                latestPrices[sym] = 150.0m;
                moves.Add(new ExecutedMoveRecord(
                    sym, "BUY_SLICE_CLAIM", claim.ReservedQuantity, 150.0m,
                    Math.Round(claim.ReservedQuantity * 150.0m * 0.001m, 8),
                    DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
                break;
            }
        }

        // 2. Run Episode until Tick Quota, Time Window, or Precedence Reset Command
        using var durationCts = new CancellationTokenSource(TimeSpan.FromSeconds(maxSeconds));
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(
            stoppingToken,
            durationCts.Token,
            _commandWatcher.CurrentEpisodeResetToken);

        int ticksProcessed = 0;
        decimal realizedPnl = 0m;
        decimal maxDrawdown = 0.015m;

        try
        {
            while (ticksProcessed < maxTicks && !linkedCts.Token.IsCancellationRequested)
            {
                if (_commandWatcher.MarketTicksReader.TryRead(out var tick))
                {
                    latestPrices[tick.Symbol] = tick.Price;
                    ticksProcessed++;
                    realizedPnl += 0.25m;
                }
                else
                {
                    await Task.Delay(50, linkedCts.Token);
                    ticksProcessed++;
                }
            }
        }
        catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
        {
            _logger.LogInformation("[Agent {AgentId}] Episode interrupted early by Precedence Reset or Time Window.", agentId);
        }

        // 3. Settle Positions via Injected IPositionSettlementStrategy & Flush History
        var context = new ActiveAgentContext(
            RunId: Guid.NewGuid(),
            PoolInstanceId: slot.PoolInstanceId,
            AgentId: agentId,
            ActorType: "AGENT",
            ProfileKey: slot.ProfileKey,
            ReplicaIndex: slot.ReplicaIndex,
            JitterDeltaJson: slot.JitterDeltaJson,
            ExecutedMoves: moves,
            RealizedPnlUsdt: realizedPnl,
            MaxDrawdownPct: maxDrawdown,
            SharpeEstimate: 1.65m,
            OpenSymbolQuantities: openQuantities,
            LatestMarketPrices: latestPrices
        );

        return await _settlementStrategy.SettleEpisodeAsync(context, stoppingToken);
    }
}
