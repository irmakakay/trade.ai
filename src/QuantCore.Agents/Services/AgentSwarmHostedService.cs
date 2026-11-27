using QuantCore.Agents.Execution;
using System.Collections.Concurrent;
using System.Text.Json;
using QuantCore.Agents.Client;
using QuantCore.Agents.Settlement;
using QuantCore.Contracts.Domain;

namespace QuantCore.Agents.Services;

public sealed record ParsedStrategyParams(
    decimal EntryThreshold,
    decimal StopLossAtr,
    decimal TakeProfitRr,
    decimal MaxSliceClaimPct,
    bool IsPromotedLive = false,
    decimal ModelConfidence = 0m,
    decimal ExpectedEdgeBps = 0m
);

public sealed record CarriedPositionState(
    string Symbol,
    decimal Quantity,
    decimal EntryPrice
);

public sealed class AgentSwarmHostedService : BackgroundService
{
    private const decimal TakerFeeRate = 0.0009m;
    private const decimal MakerFeeRate = 0.0000m;
    private const decimal BaseAtrPct = 0.0080m; // 80 bps baseline volatility unit

    private static readonly string[] AllProfiles =
    {
        "AGGRESSIVE_BREAKOUT",
        "BALANCED_SWING",
        "CAREFUL_MEAN_REVERSION"
    };

    private readonly IQuantApiClient _apiClient;
    private readonly IPositionSettlementStrategy _settlementStrategy;
    private readonly IEpisodeCommandWatcher _commandWatcher;
    private readonly IConfiguration _config;
    private readonly ILogger<AgentSwarmHostedService> _logger;
    private readonly IOrderExecutionGateway _executionGateway;

    // Tracks carried open positions across generations per (ProfileKey, Symbol) so agents
    // do not pay repeated 10 bps entry taker fees when continuing an existing trend slice.
    private readonly ConcurrentDictionary<string, CarriedPositionState> _carriedPositions = new();

    public AgentSwarmHostedService(
        IQuantApiClient apiClient,
        IPositionSettlementStrategy settlementStrategy,
        IEpisodeCommandWatcher commandWatcher,
        IConfiguration config,
        ILogger<AgentSwarmHostedService> logger,
        IOrderExecutionGateway? executionGateway = null)
    {
        _apiClient = apiClient;
        _settlementStrategy = settlementStrategy;
        _commandWatcher = commandWatcher;
        _config = config;
        _logger = logger;
        _executionGateway = executionGateway ?? new SimulatedExecutionGateway();
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        string configuredProfile = (_config["AGENT_PROFILE_KEY"] ?? "ALL").Trim().ToUpperInvariant();
        string[] targetProfiles = configuredProfile == "ALL"
            ? AllProfiles
            : configuredProfile.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        if (targetProfiles.Length == 0)
        {
            targetProfiles = AllProfiles;
        }

        int maxTicksPerEpisode = _config.GetValue<int>("EPISODE_MAX_TICKS", 40);
        int maxEpisodeSeconds = _config.GetValue<int>("EPISODE_MAX_SECONDS", 300);
        Guid agentId = Guid.NewGuid();
        int profileCursor = Random.Shared.Next(targetProfiles.Length);

        _logger.LogInformation(
            "[Agent {AgentId}] Started swarm worker | Profiles=[{Profiles}] | Mode={Mode} | MaxTicks={Ticks}",
            agentId, string.Join(",", targetProfiles), _settlementStrategy.StrategyName, maxTicksPerEpisode);

        while (!stoppingToken.IsCancellationRequested)
        {
            PoolSlotDto? slot = null;

            // Round-robin across configured profiles so all strategy pools evolve concurrently
            for (int attempt = 0; attempt < targetProfiles.Length; attempt++)
            {
                string candidateProfile = targetProfiles[(profileCursor + attempt) % targetProfiles.Length];
                slot = await _apiClient.CheckoutStrategySlotAsync(agentId, candidateProfile, stoppingToken);
                if (slot is not null)
                {
                    profileCursor = (profileCursor + attempt + 1) % targetProfiles.Length;
                    break;
                }
            }

            if (slot is null)
            {
                await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
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

        bool isCarryMode = _settlementStrategy.StrategyName.Equals("CARRY_POSITIONS", StringComparison.OrdinalIgnoreCase);

        bool allowSyntheticTrading = _config.GetValue<bool>("ALLOW_SYNTHETIC_TRADING", false);
        bool enableSignalEntryGate = _config.GetValue<bool>("ENABLE_SIGNAL_ENTRY_GATE", false);

        var openQuantities = new Dictionary<string, decimal>();
        var entryPrices = new Dictionary<string, decimal>();
        var latestPrices = new Dictionary<string, decimal>();
        var priceWindows = new Dictionary<string, Queue<decimal>>(StringComparer.OrdinalIgnoreCase);
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

                bool isSyntheticTick = string.Equals(tick.Action, "SYNTHETIC_GBM", StringComparison.OrdinalIgnoreCase);
                if (isSyntheticTick && !allowSyntheticTrading)
                {
                    continue;
                }

                latestPrices[tick.Symbol] = tick.Price;
                if (!priceWindows.TryGetValue(tick.Symbol, out var win))
                {
                    win = new Queue<decimal>(17);
                    priceWindows[tick.Symbol] = win;
                }
                win.Enqueue(tick.Price);
                if (win.Count > 16) win.Dequeue();

                ticksProcessed++;

                // 1. Entry or Carried Position Adoption (gated by strat.EntryThreshold when enabled)
                if (openQuantities.Count == 0 && entryPrices.Count == 0 && candidateSymbols.Contains(tick.Symbol))
                {
                    if (enableSignalEntryGate && !PassesEntrySignalGate(slot.ProfileKey, strat.EntryThreshold, win))
                    {
                        continue;
                    }
                    string carryKey = $"{slot.ProfileKey}:{tick.Symbol}";

                    if (isCarryMode && _carriedPositions.TryRemove(carryKey, out var carried) && carried.Quantity > 0m)
                    {
                        // Re-lock slice in API mutex without paying a duplicate 10 bps entry taker fee
                        var claim = await _apiClient.ClaimSymbolSliceAsync(
                            new ShareSliceClaimRequest(
                                agentId,
                                slot.PoolInstanceId,
                                tick.Symbol,
                                strat.MaxSliceClaimPct,
                                "LONG_ACCUMULATING"),
                            linkedCts.Token);

                        decimal activeQty = (claim is { Claimed: true, ReservedQuantity: > 0m })
                            ? claim.ReservedQuantity
                            : carried.Quantity;

                        // Only charge taker fee on net incremental quantity added above the carried position
                        decimal incrementalQty = Math.Max(0m, activeQty - carried.Quantity);
                        decimal deltaFee = Math.Round(incrementalQty * tick.Price * MakerFeeRate, 8);

                        // Mark-to-market baseline from current tick price for this episode's delta PnL
                        openQuantities[tick.Symbol] = activeQty;
                        entryPrices[tick.Symbol] = tick.Price;
                        realizedPnlUsdt -= deltaFee;

                        initialNotionalUsdt = activeQty * tick.Price;
                        peakEquityUsdt = initialNotionalUsdt - deltaFee;
                        prevEquityUsdt = peakEquityUsdt;

                        if (incrementalQty > 0m)
                        {
                            var orderRes = await _executionGateway.SubmitOrderAsync(
                                new ExecutionOrderRequest(Guid.NewGuid(), tick.Symbol, "buy", incrementalQty, tick.Price, strat.IsPromotedLive, slot.ReplicaIndex, strat.ModelConfidence, strat.ExpectedEdgeBps, "ENTRY", slot.ProfileKey, isSyntheticTick),
                                linkedCts.Token);
                            if (!orderRes.Accepted)
                            {
                                _logger.LogWarning("[Agent {AgentId}] Carry delta order rejected ({Provider}/{Mode}): {Msg}",
                                    agentId, orderRes.Provider, orderRes.Mode, orderRes.Message);
                            }
                        }

                        moves.Add(new ExecutedMoveRecord(
                            tick.Symbol,
                            "CARRY_INHERIT_SLICE",
                            activeQty,
                            tick.Price,
                            deltaFee,
                            tick.TimestampMs));
                    }
                    else
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
                            decimal entryFee = Math.Round(claim.ReservedQuantity * tick.Price * MakerFeeRate, 8);
                            openQuantities[tick.Symbol] = claim.ReservedQuantity;
                            entryPrices[tick.Symbol] = tick.Price;
                            realizedPnlUsdt -= entryFee;

                            initialNotionalUsdt = claim.ReservedQuantity * tick.Price;
                            peakEquityUsdt = initialNotionalUsdt - entryFee;
                            prevEquityUsdt = peakEquityUsdt;

                            var orderRes = await _executionGateway.SubmitOrderAsync(
                                new ExecutionOrderRequest(Guid.NewGuid(), tick.Symbol, "buy", claim.ReservedQuantity, tick.Price, strat.IsPromotedLive, slot.ReplicaIndex, strat.ModelConfidence, strat.ExpectedEdgeBps, "ENTRY", slot.ProfileKey, isSyntheticTick),
                                linkedCts.Token);
                            if (!orderRes.Accepted)
                            {
                                _logger.LogWarning("[Agent {AgentId}] Entry order rejected ({Provider}/{Mode}): {Msg}",
                                    agentId, orderRes.Provider, orderRes.Mode, orderRes.Message);
                            }

                            moves.Add(new ExecutedMoveRecord(
                                tick.Symbol,
                                "BUY_SLICE_CLAIM",
                                claim.ReservedQuantity,
                                tick.Price,
                                entryFee,
                                tick.TimestampMs));
                        }
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
                        decimal exitFee = Math.Round(currentPositionValue * (exitAction == "SELL_TAKE_PROFIT" ? MakerFeeRate : TakerFeeRate), 8);
                        decimal tradeGrossPnl = heldQty * (tick.Price - entryPrice);

                        realizedPnlUsdt += tradeGrossPnl - exitFee;
                        openQuantities[tick.Symbol] = 0m;

                        var sellRes = await _executionGateway.SubmitOrderAsync(
                            new ExecutionOrderRequest(Guid.NewGuid(), tick.Symbol, "sell", heldQty, tick.Price, strat.IsPromotedLive, slot.ReplicaIndex, strat.ModelConfidence, strat.ExpectedEdgeBps, exitAction == "SELL_TAKE_PROFIT" ? "TAKE_PROFIT" : "STOP_LOSS", slot.ProfileKey, isSyntheticTick),
                            linkedCts.Token);
                        if (!sellRes.Accepted)
                        {
                            _logger.LogWarning("[Agent {AgentId}] Exit order rejected ({Provider}/{Mode}): {Msg}",
                                agentId, sellRes.Provider, sellRes.Mode, sellRes.Message);
                        }

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

        // Evaluate open positions at episode boundary
        foreach (var (sym, qty) in openQuantities)
        {
            if (qty > 0m && latestPrices.TryGetValue(sym, out decimal lastP) && entryPrices.TryGetValue(sym, out decimal entP))
            {
                realizedPnlUsdt += qty * (lastP - entP);

                if (isCarryMode)
                {
                    _carriedPositions[$"{slot.ProfileKey}:{sym}"] = new CarriedPositionState(sym, qty, lastP);
                }
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
            bool isPromoted = root.TryGetProperty("is_promoted_live", out var pr) && pr.ValueKind == JsonValueKind.True;
            decimal modelConf = root.TryGetProperty("confidence_score", out var cf) && cf.TryGetDecimal(out var cVal) ? cVal : 0m;
            decimal edgeBps = root.TryGetProperty("expected_return_bps", out var eb) && eb.TryGetDecimal(out var eVal) ? eVal : 0m;
            return new ParsedStrategyParams(entry, sl, tp, Math.Clamp(slice, 0.01m, 1.0m), isPromoted, modelConf, edgeBps);
        }
        catch
        {
            return new ParsedStrategyParams(0.60m, 1.50m, 2.00m, 0.25m);
        }
    }

    public static bool PassesEntrySignalGate(string profileKey, decimal entryThreshold, Queue<decimal> priceWindow)
    {
        // Need a minimal rolling window to evaluate momentum / mean-reversion instead of blindly buying tick #1
        if (priceWindow.Count < 4) return false;

        decimal[] arr = priceWindow.ToArray();
        decimal current = arr[^1];
        decimal prev = arr[^2];
        decimal sum = 0m;
        decimal min = decimal.MaxValue;
        decimal max = decimal.MinValue;
        for (int i = 0; i < arr.Length; i++)
        {
            sum += arr[i];
            if (arr[i] < min) min = arr[i];
            if (arr[i] > max) max = arr[i];
        }

        decimal avg = sum / arr.Length;
        decimal range = max - min;
        if (avg <= 0m || range <= 0m) return false;

        decimal clampedThresh = Math.Clamp(entryThreshold, 0.20m, 0.95m);
        string prof = (profileKey ?? string.Empty).Trim().ToUpperInvariant();

        decimal signalScore;
        if (prof.Contains("MEAN_REVERSION"))
        {
            // Buy oversold pullbacks below rolling mean that show first uptick reversal
            decimal discount = Math.Clamp((avg - current) / (avg * 0.0012m), 0m, 1m);
            decimal bounce = current > prev ? 0.35m : 0.0m;
            signalScore = Math.Clamp(discount * 0.70m + bounce, 0m, 1m);
        }
        else if (prof.Contains("BREAKOUT"))
        {
            // Buy upward breakouts near top of rolling window with positive tick velocity
            decimal posInRange = (current - min) / range;
            decimal velocity = current > prev && current > avg ? 0.25m : -0.25m;
            signalScore = Math.Clamp(posInRange * 0.80m + velocity, 0m, 1m);
        }
        else
        {
            // BALANCED_SWING: constructive uptick near or above rolling mean
            decimal relMean = Math.Clamp(0.5m + ((current - avg) / (avg * 0.0015m)) * 0.5m, 0m, 1m);
            decimal uptick = current > prev ? 0.25m : -0.20m;
            signalScore = Math.Clamp(relMean * 0.80m + uptick, 0m, 1m);
        }

        return signalScore >= clampedThresh;
    }

    public static decimal ComputeAnnualizedSharpe(int count, double mean, double m2)
    {
        if (count < 2) return 0m;
        double variance = m2 / (count - 1);
        double stdDev = Math.Sqrt(Math.Max(variance, 1e-12));
        if (stdDev <= 1e-9) return 0m;
        double rawSharpe = (mean / stdDev) * Math.Sqrt(count);
        return Math.Round((decimal)Math.Clamp(rawSharpe, -10.0, 10.0), 4);
    }
}
