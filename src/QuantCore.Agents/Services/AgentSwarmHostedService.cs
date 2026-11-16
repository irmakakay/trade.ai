using System.Text.Json;
using QuantCore.Agents.Client;
using QuantCore.Agents.Settlement;
using QuantCore.Contracts.Domain;

namespace QuantCore.Agents.Services;

public sealed record ParsedStrategyParams(
    decimal EntryThreshold,
    decimal StopLossAtr,
    decimal TakeProfitRr,
    decimal MaxSliceClaimPct
);

public sealed class AgentSwarmHostedService : BackgroundService
{
    private const decimal TakerFeeRate = 0.0010m;
    private const decimal BaseAtrPct = 0.0080m; // 80 bps baseline volatility unit

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

        while (!stoppingToken.IsCancellationRequested)
        {
            var slot = await _apiClient.CheckoutStrategySlotAsync(agentId, profileKey, stoppingToken);
            if (slot is null)
            {
                await Task.Delay(TimeSpan.FromSeconds(3), stoppingToken);
                continue;
            }

            await RunSingleEpisodeAsync(agentId, slot, maxTicksPerEpisode, maxEpisodeSeconds, stoppingToken);
        }
    }

    public async Task<EpisodeCommitResponse?> RunSingleEpisodeAsync(
        Guid agentId,
        PoolSlotDto slot,
        int maxTicks,
        int maxSeconds,
        CancellationToken stoppingToken)
    {
        var candidateSymbols = JsonSerializer.Deserialize<List<string>>(slot.CandidateSymbolsJson)
            ?? new List<string> { "SOLUSDT" };
        var strat = ParseStrategyPayload(slot.StrategyPayloadJson);

        var openQuantities = new Dictionary<string, decimal>();
        var entryPrices = new Dictionary<string, decimal>();
        var latestPrices = new Dictionary<string, decimal>();
        var moves = new List<ExecutedMoveRecord>();

        using var durationCts = new CancellationTokenSource(TimeSpan.FromSeconds(maxSeconds));
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(
            stoppingToken,
            durationCts.Token,
            _commandWatcher.CurrentEpisodeResetToken);

        int ticksProcessed = 0;
        decimal realizedPnlUsdt = 0m;
        decimal initialNotionalUsdt = 0m;
        decimal peakEquityUsdt = 0m;
        decimal prevEquityUsdt = 0m;
        decimal maxDrawdownPct = 0m;

        // Welford online variance accumulators for tick-by-tick returns
        int returnCount = 0;
        double meanReturn = 0.0;
        double m2Return = 0.0;

        try
        {
            while (ticksProcessed < maxTicks && !linkedCts.Token.IsCancellationRequested)
            {
                var tick = await _commandWatcher.MarketTicksReader.ReadAsync(linkedCts.Token);
                if (tick.Price <= 0m) continue;

                latestPrices[tick.Symbol] = tick.Price;
                ticksProcessed++;

                // 1. Entry Claim: If we haven't claimed a slice yet and this tick matches a candidate symbol
                if (openQuantities.Count == 0 && entryPrices.Count == 0 && candidateSymbols.Contains(tick.Symbol))
                {
                    var claim = await _apiClient.ClaimSymbolSliceAsync(
                        new ShareSliceClaimRequest(
                            agentId,
                            slot.PoolInstanceId,
                            tick.Symbol,
                            strat.MaxSliceClaimPct,
                            "LONG_ACCUMULATING"),
                        linkedCts.Token);

                    if (claim is { Claimed: true, ReservedQuantity: > 0m })
                    {
                        decimal entryFee = Math.Round(claim.ReservedQuantity * tick.Price * TakerFeeRate, 8);
                        openQuantities[tick.Symbol] = claim.ReservedQuantity;
                        entryPrices[tick.Symbol] = tick.Price;
                        realizedPnlUsdt -= entryFee;

                        initialNotionalUsdt = claim.ReservedQuantity * tick.Price;
                        peakEquityUsdt = initialNotionalUsdt - entryFee;
                        prevEquityUsdt = peakEquityUsdt;

                        moves.Add(new ExecutedMoveRecord(
                            tick.Symbol,
                            "BUY_SLICE_CLAIM",
                            claim.ReservedQuantity,
                            tick.Price,
                            entryFee,
                            tick.TimestampMs));
                    }
                    continue;
                }

                // 2. Mark-to-Market Valuation, Stop-Loss / Take-Profit Check & Online Sharpe Update
                if (openQuantities.TryGetValue(tick.Symbol, out decimal heldQty) && heldQty > 0m)
                {
                    decimal entryPrice = entryPrices[tick.Symbol];
                    decimal priceReturnPct = (tick.Price - entryPrice) / entryPrice;

                    decimal stopLossPct = -strat.StopLossAtr * BaseAtrPct;
                    decimal takeProfitPct = strat.StopLossAtr * BaseAtrPct * strat.TakeProfitRr;

                    decimal currentPositionValue = heldQty * tick.Price;
                    decimal currentEquity = initialNotionalUsdt + realizedPnlUsdt + (heldQty * (tick.Price - entryPrice));

                    if (prevEquityUsdt > 0m)
                    {
                        double stepRet = (double)((currentEquity - prevEquityUsdt) / prevEquityUsdt);
                        returnCount++;
                        double delta = stepRet - meanReturn;
                        meanReturn += delta / returnCount;
                        double delta2 = stepRet - meanReturn;
                        m2Return += delta * delta2;
                    }
                    prevEquityUsdt = currentEquity;

                    if (currentEquity > peakEquityUsdt)
                    {
                        peakEquityUsdt = currentEquity;
                    }
                    else if (peakEquityUsdt > 0m)
                    {
                        decimal dd = (peakEquityUsdt - currentEquity) / peakEquityUsdt;
                        if (dd > maxDrawdownPct) maxDrawdownPct = Math.Round(dd, 4);
                    }

                    // Dynamic Stop-Loss or Take-Profit Exit
                    if (priceReturnPct <= stopLossPct || priceReturnPct >= takeProfitPct)
                    {
                        string exitAction = priceReturnPct >= takeProfitPct ? "SELL_TAKE_PROFIT" : "SELL_STOP_LOSS";
                        decimal exitFee = Math.Round(currentPositionValue * TakerFeeRate, 8);
                        decimal tradeGrossPnl = heldQty * (tick.Price - entryPrice);

                        realizedPnlUsdt += tradeGrossPnl - exitFee;
                        openQuantities[tick.Symbol] = 0m;

                        moves.Add(new ExecutedMoveRecord(
                            tick.Symbol,
                            exitAction,
                            heldQty,
                            tick.Price,
                            exitFee,
                            tick.TimestampMs));
                        break; // Position closed; settle episode immediately
                    }
                }
            }
        }
        catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
        {
            _logger.LogInformation("[Agent {AgentId}] Episode interrupted by Precedence Reset or Time Window.", agentId);
        }

        // If position is still open at episode end, include unrealized PnL in baseline before settlement strategy runs
        foreach (var (sym, qty) in openQuantities)
        {
            if (qty > 0m && latestPrices.TryGetValue(sym, out decimal lastP) && entryPrices.TryGetValue(sym, out decimal entP))
            {
                realizedPnlUsdt += qty * (lastP - entP);
            }
        }

        decimal sharpeEstimate = ComputeAnnualizedSharpe(returnCount, meanReturn, m2Return);

        var context = new ActiveAgentContext(
            RunId: Guid.NewGuid(),
            PoolInstanceId: slot.PoolInstanceId,
            AgentId: agentId,
            ActorType: "AGENT",
            ProfileKey: slot.ProfileKey,
            ReplicaIndex: slot.ReplicaIndex,
            JitterDeltaJson: slot.JitterDeltaJson,
            ExecutedMoves: moves,
            RealizedPnlUsdt: Math.Round(realizedPnlUsdt, 8),
            MaxDrawdownPct: Math.Round(maxDrawdownPct, 4),
            SharpeEstimate: sharpeEstimate,
            OpenSymbolQuantities: openQuantities,
            LatestMarketPrices: latestPrices
        );

        return await _settlementStrategy.SettleEpisodeAsync(context, stoppingToken);
    }

    public static ParsedStrategyParams ParseStrategyPayload(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            decimal entry = root.TryGetProperty("entry_threshold", out var e) ? e.GetDecimal() : 0.60m;
            decimal sl = root.TryGetProperty("stop_loss_atr", out var s) ? s.GetDecimal() : 1.50m;
            decimal tp = root.TryGetProperty("take_profit_rr", out var t) ? t.GetDecimal() : 2.00m;
            decimal slice = root.TryGetProperty("max_slice_claim_pct", out var m) ? m.GetDecimal() : 0.25m;
            return new ParsedStrategyParams(entry, sl, tp, Math.Clamp(slice, 0.01m, 1.0m));
        }
        catch
        {
            return new ParsedStrategyParams(0.60m, 1.50m, 2.00m, 0.25m);
        }
    }

    public static decimal ComputeAnnualizedSharpe(int count, double mean, double m2)
    {
        if (count < 2) return 0m;
        double variance = m2 / (count - 1);
        double stdDev = Math.Sqrt(Math.Max(variance, 1e-12));
        if (stdDev <= 1e-9) return 0m;
        // Scale step Sharpe by sqrt(N) capped to [-10, 10]
        double rawSharpe = (mean / stdDev) * Math.Sqrt(count);
        return Math.Round((decimal)Math.Clamp(rawSharpe, -10.0, 10.0), 4);
    }
}