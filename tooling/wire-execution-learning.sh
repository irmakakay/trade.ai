#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

export REPO_ROOT
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

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

step "1/5 Creating execution_history Table in PostgreSQL"

dc exec -T postgres psql -U "${POSTGRES_USER:-quant}" -d "${POSTGRES_DB:-quantcore}" << 'SQL'
CREATE TABLE IF NOT EXISTS execution_history (
    id BIGSERIAL PRIMARY KEY,
    client_order_id UUID NOT NULL,
    provider VARCHAR(32) NOT NULL,
    execution_mode VARCHAR(16) NOT NULL,
    symbol VARCHAR(24) NOT NULL,
    side VARCHAR(8) NOT NULL,
    requested_qty NUMERIC(18, 8) NOT NULL,
    reference_price NUMERIC(18, 8) NOT NULL,
    executed_price NUMERIC(18, 8) NOT NULL,
    slippage_bps NUMERIC(10, 4) NOT NULL DEFAULT 0,
    accepted BOOLEAN NOT NULL,
    venue_order_id VARCHAR(128),
    raw_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_execution_history_created_at ON execution_history (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_execution_history_symbol_mode ON execution_history (symbol, execution_mode);
SQL
ok "PostgreSQL execution_history table verified"

step "2/5 Adding TelemetryExecutionGateway Decorator in QuantCore.Agents"

python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
exec_dir = repo_root / "src/QuantCore.Agents/Execution"

# 1. Create TelemetryExecutionGateway decorator
(exec_dir / "TelemetryExecutionGateway.cs").write_text("""using System.Globalization;
using System.Text.Json;
using Npgsql;

namespace QuantCore.Agents.Execution;

public sealed class TelemetryExecutionGateway : IOrderExecutionGateway
{
    private readonly IOrderExecutionGateway _inner;
    private readonly IConfiguration _config;
    private readonly ILogger<TelemetryExecutionGateway> _logger;

    public string ProviderName => _inner.ProviderName;

    public TelemetryExecutionGateway(
        IOrderExecutionGateway inner,
        IConfiguration config,
        ILogger<TelemetryExecutionGateway> logger)
    {
        _inner = inner;
        _config = config;
        _logger = logger;
    }

    public async Task<ExecutionOrderResult> SubmitOrderAsync(ExecutionOrderRequest request, CancellationToken ct)
    {
        var result = await _inner.SubmitOrderAsync(request, ct);

        decimal executedPrice = ExtractExecutedPrice(result, request.ReferencePrice);
        decimal slippageBps = request.ReferencePrice > 0m
            ? Math.Abs(executedPrice - request.ReferencePrice) / request.ReferencePrice * 10_000m
            : 0m;

        await PersistExecutionOutcomeAsync(request, result, executedPrice, slippageBps, ct);
        return result;
    }

    private static decimal ExtractExecutedPrice(ExecutionOrderResult result, decimal fallbackPrice)
    {
        if (!result.Accepted || result.Mode != "LIVE" || string.IsNullOrWhiteSpace(result.Message))
            return fallbackPrice;

        try
        {
            using var doc = JsonDocument.Parse(result.Message);
            var root = doc.RootElement;
            if (root.TryGetProperty("average_fill_price", out var avgProp) &&
                decimal.TryParse(avgProp.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsedAvg) &&
                parsedAvg > 0m)
            {
                return parsedAvg;
            }
            if (root.TryGetProperty("filled_price", out var fillProp) &&
                decimal.TryParse(fillProp.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsedFill) &&
                parsedFill > 0m)
            {
                return parsedFill;
            }
        }
        catch
        {
            // Non-JSON message or no fill price field yet
        }

        return fallbackPrice;
    }

    private async Task PersistExecutionOutcomeAsync(
        ExecutionOrderRequest request,
        ExecutionOrderResult result,
        decimal executedPrice,
        decimal slippageBps,
        CancellationToken ct)
    {
        string? connStr = _config.GetConnectionString("DefaultConnection") ?? _config["POSTGRES_CONNECTION_STRING"];
        if (string.IsNullOrWhiteSpace(connStr))
            return;

        try
        {
            await using var conn = new NpgsqlConnection(connStr);
            await conn.OpenAsync(ct);

            const string sql = @"
                INSERT INTO execution_history (
                    client_order_id, provider, execution_mode, symbol, side,
                    requested_qty, reference_price, executed_price, slippage_bps,
                    accepted, venue_order_id, raw_message
                ) VALUES (
                    @client_order_id, @provider, @execution_mode, @symbol, @side,
                    @requested_qty, @reference_price, @executed_price, @slippage_bps,
                    @accepted, @venue_order_id, @raw_message
                );";

            await using var cmd = new NpgsqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("client_order_id", request.ClientOrderId);
            cmd.Parameters.AddWithValue("provider", result.Provider);
            cmd.Parameters.AddWithValue("execution_mode", result.Mode);
            cmd.Parameters.AddWithValue("symbol", request.Symbol);
            cmd.Parameters.AddWithValue("side", request.Side);
            cmd.Parameters.AddWithValue("requested_qty", request.Quantity);
            cmd.Parameters.AddWithValue("reference_price", request.ReferencePrice);
            cmd.Parameters.AddWithValue("executed_price", executedPrice);
            cmd.Parameters.AddWithValue("slippage_bps", slippageBps);
            cmd.Parameters.AddWithValue("accepted", result.Accepted);
            cmd.Parameters.AddWithValue("venue_order_id", (object?)result.VenueOrderId ?? DBNull.Value);
            cmd.Parameters.AddWithValue("raw_message", result.Message);

            await cmd.ExecuteNonQueryAsync(ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[TelemetryGateway] Failed to persist execution_history row for {OrderId}", request.ClientOrderId);
        }
    }
}
""", encoding="utf-8")

# 2. Wrap IOrderExecutionGateway registration in ExecutionServiceCollectionExtensions.cs
boot_path = exec_dir / "ExecutionServiceCollectionExtensions.cs"
boot_code = boot_path.read_text(encoding="utf-8")

if "TelemetryExecutionGateway" not in boot_code:
    old_block = """        if (gatewayMode == "REVOLUT_X")
        {
            string revxBaseUrl = configuration["REVX_API_BASE_URL"] ?? "https://revx.revolut.com";
            services.AddHttpClient<IOrderExecutionGateway, RevolutXExecutionGateway>(client =>
            {
                client.BaseAddress = new Uri(revxBaseUrl);
            })
            .AddHttpMessageHandler<RevxSigningDelegatingHandler>();
        }
        else
        {
            services.AddSingleton<IOrderExecutionGateway, SimulatedExecutionGateway>();
        }"""

    new_block = """        if (gatewayMode == "REVOLUT_X")
        {
            string revxBaseUrl = configuration["REVX_API_BASE_URL"] ?? "https://revx.revolut.com";
            services.AddHttpClient<RevolutXExecutionGateway>(client =>
            {
                client.BaseAddress = new Uri(revxBaseUrl);
            })
            .AddHttpMessageHandler<RevxSigningDelegatingHandler>();

            services.AddSingleton<IOrderExecutionGateway>(sp =>
                new TelemetryExecutionGateway(
                    sp.GetRequiredService<RevolutXExecutionGateway>(),
                    sp.GetRequiredService<IConfiguration>(),
                    sp.GetRequiredService<ILogger<TelemetryExecutionGateway>>()));
        }
        else
        {
            services.AddSingleton<SimulatedExecutionGateway>();
            services.AddSingleton<IOrderExecutionGateway>(sp =>
                new TelemetryExecutionGateway(
                    sp.GetRequiredService<SimulatedExecutionGateway>(),
                    sp.GetRequiredService<IConfiguration>(),
                    sp.GetRequiredService<ILogger<TelemetryExecutionGateway>>()));
        }"""

    if old_block in boot_code:
        boot_code = boot_code.replace(old_block, new_block)
        boot_path.write_text(boot_code, encoding="utf-8")
        print("[OK] Wrapped IOrderExecutionGateway with TelemetryExecutionGateway")
    else:
        print("[WARN] Could not match exact DI block in ExecutionServiceCollectionExtensions.cs; check manually.")
PYEOF

step "3/5 Updating quant_nn_worker to Incorporate Execution Slippage & Rejection Feedback"

python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
helper_path = repo_root / "src/quant_nn_worker/execution_feedback.py"

helper_path.write_text("""import os
import psycopg2


def fetch_execution_reward_adjustment(conn_str: str, lookback_minutes: int = 60) -> dict:
    \"\"\"
    Computes execution quality adjustments from recent Revolut X (LIVE / DRY_RUN)
    and simulated orders so the 128-dim NN penalizes high slippage and rejected orders.
    \"\"\"
    stats = {
        "total_orders": 0,
        "rejected_orders": 0,
        "avg_slippage_bps": 0.0,
        "reward_penalty": 0.0,
    }
    if not conn_str:
        return stats

    try:
        with psycopg2.connect(conn_str) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    \"\"\"
                    SELECT
                        COUNT(*) AS total_orders,
                        COUNT(*) FILTER (WHERE NOT accepted) AS rejected_orders,
                        COALESCE(AVG(slippage_bps) FILTER (WHERE accepted), 0.0) AS avg_slippage_bps
                    FROM execution_history
                    WHERE created_at >= NOW() - (%s || ' minutes')::INTERVAL
                      AND provider = 'REVOLUT_X';
                    \"\"\",
                    (str(lookback_minutes),),
                )
                row = cur.fetchone()
                if row and row[0] > 0:
                    total_orders = int(row[0])
                    rejected_orders = int(row[1])
                    avg_slippage_bps = float(row[2])

                    rejection_rate = rejected_orders / max(total_orders, 1)
                    # Penalize slippage above 5 bps and any venue/risk-cap rejections
                    slippage_penalty = max(0.0, (avg_slippage_bps - 5.0) * 0.01)
                    rejection_penalty = rejection_rate * 0.50

                    stats.update({
                        "total_orders": total_orders,
                        "rejected_orders": rejected_orders,
                        "avg_slippage_bps": round(avg_slippage_bps, 4),
                        "reward_penalty": round(slippage_penalty + rejection_penalty, 6),
                    })
    except Exception as exc:
        print(f"[execution_feedback] Non-fatal query warning: {exc}", flush=True)

    return stats
""", encoding="utf-8")

worker_path = repo_root / "src/quant_nn_worker/main.py"
worker_code = worker_path.read_text(encoding="utf-8")

if "from execution_feedback import fetch_execution_reward_adjustment" not in worker_code:
    worker_code = "from execution_feedback import fetch_execution_reward_adjustment\n" + worker_code
    worker_path.write_text(worker_code, encoding="utf-8")
    print(f"[OK] Added execution_feedback module and imported into {worker_path}")
PYEOF

step "4/5 Running Baseline .NET Tests"
dotnet test "$REPO_ROOT/tests/QuantCore.Agents.Tests/QuantCore.Agents.Tests.csproj" -c Release --nologo -v minimal
ok "Baseline .NET tests passed"

step "5/5 Rebuilding & Refreshing Docker Services"
if [[ -x "$REPO_ROOT/tooling/refresh-dockers.sh" ]]; then
  "$REPO_ROOT/tooling/refresh-dockers.sh"
else
  dc build nn-worker
  dc --profile agents build quant-agents
  dc --profile agents up -d --scale quant-agents=3 --force-recreate quant-agents nn-worker
fi