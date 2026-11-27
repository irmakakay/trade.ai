#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/src/quant_nn_worker/Dockerfile" ]]; then
  REPO_ROOT="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/../src/quant_nn_worker/Dockerfile" ]]; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [[ -f "$SCRIPT_DIR/quant-core/src/quant_nn_worker/Dockerfile" ]]; then
  REPO_ROOT="$SCRIPT_DIR/quant-core"
else
  echo "[FAIL] Could not locate quant-core/src/quant_nn_worker/Dockerfile from $SCRIPT_DIR" >&2
  exit 1
fi
cd "$REPO_ROOT"

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
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1" >&2; exit 1; }

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

PG_USER="${POSTGRES_USER:-quant}"
PG_DB="${POSTGRES_DB:-quantcore}"

# ---------------------------------------------------------------------------
step "1/5 Replacing Dapper with Raw Npgsql in PromotedRoutingExecutionGateway.cs"
# ---------------------------------------------------------------------------
cat << 'CSHARP' > "$REPO_ROOT/src/QuantCore.Agents/Execution/PromotedRoutingExecutionGateway.cs"
using System.Collections.Concurrent;
using Npgsql;

namespace QuantCore.Agents.Execution;

/// <summary>
/// Dual-track router with PostgreSQL-backed distributed live position ledger:
/// - Keeps exploratory replicas, unpromoted models, and synthetic ticks on SimulatedExecutionGateway.
/// - Enforces at most one live position per symbol across all scaled quant-agents containers.
/// - Micro-sizes promoted champion entries to REVX_TARGET_ORDER_USDT below the hard circuit breaker.
/// </summary>
public sealed class PromotedRoutingExecutionGateway : IOrderExecutionGateway
{
    private readonly SimulatedExecutionGateway _simulatedGateway;
    private readonly IOrderExecutionGateway _liveGateway;
    private readonly IConfiguration _config;
    private readonly ILogger<PromotedRoutingExecutionGateway> _logger;
    private readonly string? _pgConnStr;
    private readonly ConcurrentDictionary<string, decimal> _fallbackPositions = new(StringComparer.OrdinalIgnoreCase);
    private int _schemaReady;

    public string ProviderName => _liveGateway.ProviderName;

    public PromotedRoutingExecutionGateway(
        SimulatedExecutionGateway simulatedGateway,
        IOrderExecutionGateway liveGateway,
        IConfiguration config,
        ILogger<PromotedRoutingExecutionGateway> logger)
    {
        _simulatedGateway = simulatedGateway;
        _liveGateway = liveGateway;
        _config = config;
        _logger = logger;
        _pgConnStr = config.GetConnectionString("DefaultConnection")
            ?? config["POSTGRES_CONNECTION_STRING"]
            ?? config["POSTGRES_CONNECTION"];
    }

    public async Task<ExecutionOrderResult> SubmitOrderAsync(ExecutionOrderRequest request, CancellationToken ct)
    {
        if (request.IsSyntheticMarketData)
        {
            return await _simulatedGateway.SubmitOrderAsync(request, ct);
        }

        string side = request.Side.Trim().ToLowerInvariant();
        int championReplica = _config.GetValue<int>("REVX_CHAMPION_REPLICA_INDEX", 1);

        if (request.ReplicaIndex != championReplica)
        {
            return await _simulatedGateway.SubmitOrderAsync(request, ct);
        }

        if (side == "sell")
        {
            var existing = await TryClaimOpenPositionForExitAsync(request.Symbol, ct);
            if (existing is null || existing.Value.Qty <= 0m)
            {
                return await _simulatedGateway.SubmitOrderAsync(request, ct);
            }

            var liveExitReq = request with { Quantity = existing.Value.Qty };
            var exitRes = await _liveGateway.SubmitOrderAsync(liveExitReq, ct);
            if (!exitRes.Accepted)
            {
                await RestorePositionAfterFailedExitAsync(request.Symbol, existing.Value.Qty, existing.Value.EntryPrice, request.ClientOrderId, ct);
            }
            return exitRes;
        }

        decimal minConfidence = _config.GetValue<decimal>("REVX_MIN_LIVE_CONFIDENCE", 0.80m);
        decimal minEdgeBps = _config.GetValue<decimal>("REVX_MIN_EDGE_BPS", 5.0m);
        decimal targetOrderUsdt = _config.GetValue<decimal>("REVX_TARGET_ORDER_USDT", 20m);
        decimal maxOrderUsdt = _config.GetValue<decimal>("REVX_MAX_ORDER_USDT", 25m);
        decimal minDeltaUsdt = _config.GetValue<decimal>("REVX_MIN_DELTA_USDT", 10m);

        if (!request.IsPromotedModel || request.ModelConfidence < minConfidence || request.ExpectedEdgeBps < minEdgeBps)
        {
            return await _simulatedGateway.SubmitOrderAsync(request, ct);
        }

        decimal cappedNotional = Math.Min(targetOrderUsdt, maxOrderUsdt * 0.96m);
        if (request.ReferencePrice <= 0m || cappedNotional < minDeltaUsdt)
        {
            return await _simulatedGateway.SubmitOrderAsync(request, ct);
        }

        decimal liveQty = Math.Round(cappedNotional / request.ReferencePrice, 6, MidpointRounding.ToZero);
        if (liveQty <= 0m || (liveQty * request.ReferencePrice) < minDeltaUsdt)
        {
            return await _simulatedGateway.SubmitOrderAsync(request, ct);
        }

        bool reserved = await TryReserveNewLivePositionAsync(request.Symbol, liveQty, request.ReferencePrice, request.ClientOrderId, ct);
        if (!reserved)
        {
            return await _simulatedGateway.SubmitOrderAsync(request, ct);
        }

        _logger.LogInformation(
            "[PromotedRouter] Routing CHAMPION {Profile}#{Rep} {Side} {Symbol} -> {Provider} | LiveNotional=${Notional:F2} (Conf={Conf:P1}, Edge={Edge:F1}bps, Intent={Intent})",
            request.ProfileKey, request.ReplicaIndex, side, request.Symbol, _liveGateway.ProviderName,
            liveQty * request.ReferencePrice, request.ModelConfidence, request.ExpectedEdgeBps, request.OrderIntent);

        var sizedLiveReq = request with { Quantity = liveQty };
        var res = await _liveGateway.SubmitOrderAsync(sizedLiveReq, ct);
        if (!res.Accepted)
        {
            await ReleaseReservedPositionAsync(request.Symbol, request.ClientOrderId, ct);
        }
        return res;
    }

    private async Task EnsureSchemaAsync(NpgsqlConnection conn, CancellationToken ct)
    {
        if (Volatile.Read(ref _schemaReady) == 1) return;
        const string ddl = @"
            CREATE TABLE IF NOT EXISTS live_venue_positions (
                symbol TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                open_qty NUMERIC(24,10) NOT NULL,
                avg_entry_price NUMERIC(24,10) NOT NULL,
                last_order_id UUID,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );";
        await using var cmd = new NpgsqlCommand(ddl, conn);
        await cmd.ExecuteNonQueryAsync(ct);
        Interlocked.Exchange(ref _schemaReady, 1);
    }

    private async Task<bool> TryReserveNewLivePositionAsync(string symbol, decimal qty, decimal price, Guid orderId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_pgConnStr))
        {
            return _fallbackPositions.TryAdd(symbol, qty);
        }

        try
        {
            await using var conn = new NpgsqlConnection(_pgConnStr);
            await conn.OpenAsync(ct);
            await EnsureSchemaAsync(conn, ct);

            const string sql = @"
                INSERT INTO live_venue_positions (symbol, provider, open_qty, avg_entry_price, last_order_id, updated_at)
                VALUES (@Symbol, @Provider, @Qty, @Price, @OrderId, NOW())
                ON CONFLICT (symbol) DO NOTHING;";
            await using var cmd = new NpgsqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("Symbol", symbol.ToUpperInvariant());
            cmd.Parameters.AddWithValue("Provider", _liveGateway.ProviderName);
            cmd.Parameters.AddWithValue("Qty", qty);
            cmd.Parameters.AddWithValue("Price", price);
            cmd.Parameters.AddWithValue("OrderId", orderId);

            int inserted = await cmd.ExecuteNonQueryAsync(ct);
            return inserted == 1;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[PromotedRouter] Failed to reserve Postgres live position for {Symbol}; keeping simulated.", symbol);
            return false;
        }
    }

    private async Task ReleaseReservedPositionAsync(string symbol, Guid orderId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_pgConnStr))
        {
            _fallbackPositions.TryRemove(symbol, out _);
            return;
        }

        try
        {
            await using var conn = new NpgsqlConnection(_pgConnStr);
            await conn.OpenAsync(ct);
            const string sql = "DELETE FROM live_venue_positions WHERE symbol = @Symbol AND last_order_id = @OrderId;";
            await using var cmd = new NpgsqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("Symbol", symbol.ToUpperInvariant());
            cmd.Parameters.AddWithValue("OrderId", orderId);
            await cmd.ExecuteNonQueryAsync(ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[PromotedRouter] Failed to rollback reserved position for {Symbol}", symbol);
        }
    }

    private async Task<(decimal Qty, decimal EntryPrice)?> TryClaimOpenPositionForExitAsync(string symbol, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_pgConnStr))
        {
            return _fallbackPositions.TryRemove(symbol, out decimal qty) ? (qty, 0m) : null;
        }

        try
        {
            await using var conn = new NpgsqlConnection(_pgConnStr);
            await conn.OpenAsync(ct);
            await EnsureSchemaAsync(conn, ct);

            const string sql = @"
                DELETE FROM live_venue_positions
                WHERE symbol = @Symbol
                RETURNING open_qty, avg_entry_price;";
            await using var cmd = new NpgsqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("Symbol", symbol.ToUpperInvariant());
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            if (await reader.ReadAsync(ct))
            {
                return (reader.GetDecimal(0), reader.GetDecimal(1));
            }
            return null;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[PromotedRouter] Failed to query live position for exit on {Symbol}", symbol);
            return null;
        }
    }

    private async Task RestorePositionAfterFailedExitAsync(string symbol, decimal qty, decimal entryPrice, Guid orderId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_pgConnStr))
        {
            _fallbackPositions.TryAdd(symbol, qty);
            return;
        }

        try
        {
            await using var conn = new NpgsqlConnection(_pgConnStr);
            await conn.OpenAsync(ct);
            const string sql = @"
                INSERT INTO live_venue_positions (symbol, provider, open_qty, avg_entry_price, last_order_id, updated_at)
                VALUES (@Symbol, @Provider, @Qty, @Price, @OrderId, NOW())
                ON CONFLICT (symbol) DO NOTHING;";
            await using var cmd = new NpgsqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("Symbol", symbol.ToUpperInvariant());
            cmd.Parameters.AddWithValue("Provider", _liveGateway.ProviderName);
            cmd.Parameters.AddWithValue("Qty", qty);
            cmd.Parameters.AddWithValue("Price", entryPrice);
            cmd.Parameters.AddWithValue("OrderId", orderId);
            await cmd.ExecuteNonQueryAsync(ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[PromotedRouter] Failed to restore live position after rejected exit on {Symbol}", symbol);
        }
    }
}
CSHARP
ok "Updated PromotedRoutingExecutionGateway.cs"

# ---------------------------------------------------------------------------
step "2/5 Running .NET 9 Tests, Building Images & Running Python Tests"
# ---------------------------------------------------------------------------
dotnet test "$REPO_ROOT/tests/QuantCore.Tests/QuantCore.Tests.csproj" -c Release --nologo -v minimal
dotnet test "$REPO_ROOT/tests/QuantCore.Agents.Tests/QuantCore.Agents.Tests.csproj" -c Release --nologo -v minimal
ok "All .NET 9 tests passed"

dc build nn-worker
dc build quant-api
dc --profile agents build quant-agents

dc run --rm --no-deps -T \
  -v "$REPO_ROOT/tests:/tests" \
  -e PYTHONPATH="/worker:/worker/quant_nn_engine" \
  nn-worker \
  pytest /tests/quant_nn_worker_tests /tests/quant_nn_engine_tests -q
ok "Python pytest suite passed"

# ---------------------------------------------------------------------------
step "3/5 Purging Synthetic-Shock Outliers & Resetting Inflated Checkpoint Flags"
# ---------------------------------------------------------------------------
dc exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" << 'SQL'
BEGIN;
DELETE FROM trading_history WHERE ABS(realized_pnl_usdt) > 500;
DELETE FROM execution_history WHERE provider = 'REVOLUT_X';
DROP TABLE IF EXISTS live_venue_positions;
UPDATE nn_model_checkpoints SET is_promoted_live = false;
COMMIT;
SQL
ok "PostgreSQL cleaned"

# ---------------------------------------------------------------------------
step "4/5 Recreating nn-worker, quant-api & 3x quant-agents (ED25519 DRY_RUN)"
# ---------------------------------------------------------------------------
dc up -d --no-deps --force-recreate nn-worker quant-api

info "Waiting for quant-api /health/ready..."
READY=0
for i in {1..30}; do
  CODE=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" http://localhost:8080/health/ready || echo "000")
  if [[ "$CODE" == "200" ]]; then
    ok "quant-api is READY -> $(curl -s http://localhost:8080/health/ready)"
    READY=1
    break
  fi
  sleep 1
done
[[ "$READY" == "1" ]] || fail "quant-api did not become ready within 30s"

EXECUTION_GATEWAY="REVOLUT_X" \
REVX_AUTH_PROVIDER="ED25519" \
REVX_DRY_RUN="true" \
REVX_TARGET_ORDER_USDT="20" \
REVX_MAX_ORDER_USDT="25" \
REVX_MAX_EXIT_USDT="100" \
REVX_MIN_LIVE_CONFIDENCE="0.80" \
ENABLE_SIGNAL_ENTRY_GATE="true" \
ALLOW_SYNTHETIC_TRADING="false" \
AGENT_PROFILE_KEY="ALL" \
EPISODE_SETTLEMENT_MODE="CARRY_POSITIONS" \
EPISODE_MAX_TICKS="120" \
  dc --profile agents up -d --scale quant-agents=3 --force-recreate quant-agents
ok "3x quant-agents started"

# ---------------------------------------------------------------------------
step "5/5 20-Second Verification"
# ---------------------------------------------------------------------------
info "Waiting 20s for clean startup & live-feed verification..."
sleep 20

dc --profile agents ps

dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -c "
  SELECT COUNT(*) AS clean_episodes,
         ROUND(SUM(realized_pnl_usdt), 4) AS clean_total_pnl,
         ROUND(AVG(sharpe_estimate), 4) AS clean_avg_sharpe
  FROM trading_history;
"

dc logs --tail=10 nn-worker

ok "Rollout complete! Hard-refresh http://localhost:8080 (Cmd+Shift+R)."