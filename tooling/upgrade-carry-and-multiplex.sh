#!/usr/bin/env bash
set -uo pipefail

# Automatically switch to the quant-core/ repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain
export COMPOSE_DOCKER_CLI_BUILD=1

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step() { echo -e "\n${CYAN}━━━ [$(date +%H:%M:%S)] $1 ━━━${NC}"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

run_guarded() {
  local timeout_sec="$1"
  local label="$2"
  shift 2

  info "Running: ${label} (timeout: ${timeout_sec}s)..."
  local log_file="/tmp/quant_multiplex_$$.log"
  rm -f "$log_file"

  "$@" >"$log_file" 2>&1 &
  local cmd_pid=$!
  local elapsed=0

  while kill -0 "$cmd_pid" 2>/dev/null; do
    local last_line=""
    if [[ -s "$log_file" ]]; then
      last_line=$(tail -n 1 "$log_file" | tr -d '\r' | cut -c1-70)
    fi
    printf "\r  ⏳ [%3ds / %3ds] %s -> %-70s" "$elapsed" "$timeout_sec" "$label" "${last_line:-working...}"
    sleep 1
    elapsed=$((elapsed + 1))

    if [[ "$elapsed" -ge "$timeout_sec" ]]; then
      echo ""
      fail "TIMEOUT (${timeout_sec}s) during: ${label}"
      kill -9 "$cmd_pid" 2>/dev/null || true
      tail -n 20 "$log_file" 2>/dev/null || true
      rm -f "$log_file"
      return 1
    fi
  done

  wait "$cmd_pid"
  local exit_code=$?
  printf "\r\033[K"

  if [[ "$exit_code" -ne 0 ]]; then
    fail "${label} failed (exit code ${exit_code})"
    tail -n 25 "$log_file" 2>/dev/null || true
    rm -f "$log_file"
    return "$exit_code"
  fi

  rm -f "$log_file"
  return 0
}

step "1/4 Patching AgentSwarmHostedService.cs (True Carry + Multi-Profile Multiplexing)"

python3 - << 'PYEOF'
from pathlib import Path

agent_svc_path = Path("src/QuantCore.Agents/Services/AgentSwarmHostedService.cs")
agent_svc_path.write_text("""using System.Collections.Concurrent;
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

public sealed record CarriedPositionState(
    string Symbol,
    decimal Quantity,
    decimal EntryPrice
);

public sealed class AgentSwarmHostedService : BackgroundService
{
    private const decimal TakerFeeRate = 0.0010m;
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

    // Tracks carried open positions across generations per (ProfileKey, Symbol) so agents
    // do not pay repeated 10 bps entry taker fees when continuing an existing trend slice.
    private readonly ConcurrentDictionary<string, CarriedPositionState> _carriedPositions = new();

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

                // 1. Entry or Carried Position Adoption
                if (openQuantities.Count == 0 && entryPrices.Count == 0 && candidateSymbols.Contains(tick.Symbol))
                {
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
                        decimal deltaFee = Math.Round(incrementalQty * tick.Price * TakerFeeRate, 8);

                        // Mark-to-market baseline from current tick price for this episode's delta PnL
                        openQuantities[tick.Symbol] = activeQty;
                        entryPrices[tick.Symbol] = tick.Price;
                        realizedPnlUsdt -= deltaFee;

                        initialNotionalUsdt = activeQty * tick.Price;
                        peakEquityUsdt = initialNotionalUsdt - deltaFee;
                        prevEquityUsdt = peakEquityUsdt;

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
        double rawSharpe = (mean / stdDev) * Math.Sqrt(count);
        return Math.Round((decimal)Math.Clamp(rawSharpe, -10.0, 10.0), 4);
    }
}
""", encoding="utf-8")
print("[OK] Updated src/QuantCore.Agents/Services/AgentSwarmHostedService.cs")

# Update docker-compose.yml defaults to ALL profiles + CARRY_POSITIONS
dc_path = Path("docker-compose.yml")
dc_code = dc_path.read_text(encoding="utf-8")
dc_code = dc_code.replace(
    "AGENT_PROFILE_KEY: ${AGENT_PROFILE_KEY:-AGGRESSIVE_BREAKOUT}",
    "AGENT_PROFILE_KEY: ${AGENT_PROFILE_KEY:-ALL}"
).replace(
    "EPISODE_SETTLEMENT_MODE: ${EPISODE_SETTLEMENT_MODE:-LIQUIDATE_AND_RELEASE}",
    "EPISODE_SETTLEMENT_MODE: ${EPISODE_SETTLEMENT_MODE:-CARRY_POSITIONS}"
)
dc_path.write_text(dc_code, encoding="utf-8")
print("[OK] Updated docker-compose.yml defaults (ALL profiles + CARRY_POSITIONS)")
PYEOF

step "2/4 Running .NET Unit Tests (QuantCore.Agents.Tests)"
run_guarded 120 "Running dotnet test on QuantCore.Agents.Tests" \
  dotnet test tests/QuantCore.Agents.Tests/QuantCore.Agents.Tests.csproj -c Release --nologo -v minimal
ok "All .NET agent unit tests pass"

step "3/4 Rebuilding quant-agents & Resetting Pool Slots"
run_guarded 180 "Building quant-agents image" docker compose --profile agents build quant-agents

docker compose exec -T postgres psql -U quant -d quantcore -c "
  UPDATE strategy_allocations SET status = 'RELEASED' WHERE status = 'ACTIVE';
  UPDATE portfolio_inventory SET allocated_quantity = 0;
  UPDATE strategy_pool SET status = 'AVAILABLE' WHERE status = 'CLAIMED';
"
ok "Pool slots and inventory ready across all 3 profiles"

step "4/4 Launching 3x Multi-Profile Carry Agents & Streaming Logs"
AGENT_PROFILE_KEY="ALL" \
EPISODE_SETTLEMENT_MODE="CARRY_POSITIONS" \
EPISODE_MAX_TICKS=25 \
  run_guarded 45 "Starting 3 multiplexed quant-agents replicas" \
  docker compose --profile agents up -d --scale quant-agents=3 --force-recreate quant-agents

ok "Multi-profile swarm running! Watching AGGRESSIVE_BREAKOUT, BALANCED_SWING & CAREFUL_MEAN_REVERSION evolve:"
docker compose --profile agents logs -f --tail=20 quant-agents nn-worker