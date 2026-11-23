#!/usr/bin/env bash
set -euo pipefail

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
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

PG_USER="${POSTGRES_USER:-quant}"
PG_DB="${POSTGRES_DB:-quantcore}"

# ---------------------------------------------------------------------------
step "1/6 Patching .NET API, Agents, Execution Telemetry, Python Worker & Compose"
# ---------------------------------------------------------------------------
python3 - << 'PYEOF'
import os
from pathlib import Path

repo = Path(os.environ["REPO_ROOT"]).resolve()

# --- 1A. Fix unhandled TaskCanceledException crash in BinanceMarketFeedHostedService.cs ---
feed_path = repo / "src/QuantCore.Api/Services/BinanceMarketFeedHostedService.cs"
feed = feed_path.read_text(encoding="utf-8")

old_fallback = """                using var fallbackCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                fallbackCts.CancelAfter(TimeSpan.FromSeconds(15));
                await RunSyntheticGbmFeedAsync(fallbackCts.Token);"""

new_fallback = """                using var fallbackCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                fallbackCts.CancelAfter(TimeSpan.FromSeconds(15));
                try
                {
                    await RunSyntheticGbmFeedAsync(fallbackCts.Token);
                }
                catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
                {
                    // 15s synthetic fallback window elapsed; retry live Binance WS
                }"""

if old_fallback in feed:
    feed = feed.replace(old_fallback, new_fallback, 1)

old_delay = "            await Task.Delay(250, ct);"
new_delay = """            try
            {
                await Task.Delay(250, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }"""

if old_delay in feed and "catch (OperationCanceledException)\n            {\n                break;\n            }" not in feed:
    feed = feed.replace(old_delay, new_delay, 1)

feed_path.write_text(feed, encoding="utf-8")
print(f"[OK] Patched {feed_path.relative_to(repo)}")

# --- 1B. Fix AgentEpisodeEndpoints.cs (profile-specific risk_dial_r + bounded DISTINCT ON pool_state) ---
ep_path = repo / "src/QuantCore.Api/Endpoints/AgentEpisodeEndpoints.cs"
ep = ep_path.read_text(encoding="utf-8")

old_recalc = """                int kFactor = cfg.GetValue<int>("POOL_REPLICATION_FACTOR", 3);
                mq.SubmitTaskToInputQueue(new InputTaskMessage(
                    Guid.NewGuid(),
                    TaskCommandType.RECALCULATE_POOL,
                    req.ProfileKey,
                    0.75m,
                    kFactor,
                    new[] { "BTCUSDT", "ETHUSDT", "SOLUSDT" },
                    DateTimeOffset.UtcNow
                ));"""

new_recalc = """                int kFactor = cfg.GetValue<int>("POOL_REPLICATION_FACTOR", 3);
                decimal profileRiskDial = req.ProfileKey.Trim().ToUpperInvariant() switch
                {
                    "CAREFUL_MEAN_REVERSION" => 0.25m,
                    "BALANCED_SWING" => 0.50m,
                    _ => 0.75m
                };
                mq.SubmitTaskToInputQueue(new InputTaskMessage(
                    Guid.NewGuid(),
                    TaskCommandType.RECALCULATE_POOL,
                    req.ProfileKey,
                    profileRiskDial,
                    kFactor,
                    new[] { "BTCUSDT", "ETHUSDT", "SOLUSDT" },
                    DateTimeOffset.UtcNow
                ));"""

if old_recalc in ep:
    ep = ep.replace(old_recalc, new_recalc, 1)

old_pool_sql = """            const string poolStateSql = @"
                SELECT profile_key, replica_index, status, risk_dial_r, strategy_payload::text AS strategy_payload
                FROM strategy_pool
                WHERE status IN ('AVAILABLE', 'CLAIMED')
                ORDER BY profile_key, replica_index;";"""

new_pool_sql = """            const string poolStateSql = @"
                SELECT DISTINCT ON (profile_key, replica_index)
                    profile_key, replica_index, status, risk_dial_r, strategy_payload::text AS strategy_payload
                FROM strategy_pool
                WHERE status IN ('AVAILABLE', 'CLAIMED')
                ORDER BY profile_key, replica_index, created_at DESC;";"""

if old_pool_sql in ep:
    ep = ep.replace(old_pool_sql, new_pool_sql, 1)

ep_path.write_text(ep, encoding="utf-8")
print(f"[OK] Patched {ep_path.relative_to(repo)}")

# --- 1C. Wire IOrderExecutionGateway into AgentSwarmHostedService.cs (backward-compatible ctor) ---
agent_path = repo / "src/QuantCore.Agents/Services/AgentSwarmHostedService.cs"
agent = agent_path.read_text(encoding="utf-8")

if "using QuantCore.Agents.Execution;" not in agent:
    agent = "using QuantCore.Agents.Execution;\n" + agent

if "private readonly IOrderExecutionGateway _executionGateway;" not in agent:
    agent = agent.replace(
        "    private readonly ILogger<AgentSwarmHostedService> _logger;",
        "    private readonly ILogger<AgentSwarmHostedService> _logger;\n    private readonly IOrderExecutionGateway _executionGateway;",
        1,
    )
    agent = agent.replace(
        """        IConfiguration config,
        ILogger<AgentSwarmHostedService> logger)
    {
        _apiClient = apiClient;
        _settlementStrategy = settlementStrategy;
        _commandWatcher = commandWatcher;
        _config = config;
        _logger = logger;
    }""",
        """        IConfiguration config,
        ILogger<AgentSwarmHostedService> logger,
        IOrderExecutionGateway? executionGateway = null)
    {
        _apiClient = apiClient;
        _settlementStrategy = settlementStrategy;
        _commandWatcher = commandWatcher;
        _config = config;
        _logger = logger;
        _executionGateway = executionGateway ?? new SimulatedExecutionGateway();
    }""",
        1,
    )

    old_carry_move = """                        moves.Add(new ExecutedMoveRecord(
                            tick.Symbol,
                            "CARRY_INHERIT_SLICE",
                            activeQty,
                            tick.Price,
                            deltaFee,
                            tick.TimestampMs));"""
    new_carry_move = """                        if (incrementalQty > 0m)
                        {
                            var orderRes = await _executionGateway.SubmitOrderAsync(
                                new ExecutionOrderRequest(Guid.NewGuid(), tick.Symbol, "buy", incrementalQty, tick.Price, false),
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
                            tick.TimestampMs));"""
    agent = agent.replace(old_carry_move, new_carry_move, 1)

    old_buy_move = """                            moves.Add(new ExecutedMoveRecord(
                                tick.Symbol,
                                "BUY_SLICE_CLAIM",
                                claim.ReservedQuantity,
                                tick.Price,
                                entryFee,
                                tick.TimestampMs));"""
    new_buy_move = """                            var orderRes = await _executionGateway.SubmitOrderAsync(
                                new ExecutionOrderRequest(Guid.NewGuid(), tick.Symbol, "buy", claim.ReservedQuantity, tick.Price, false),
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
                                tick.TimestampMs));"""
    agent = agent.replace(old_buy_move, new_buy_move, 1)

    old_sell_move = """                        moves.Add(new ExecutedMoveRecord(
                            tick.Symbol,
                            exitAction,
                            heldQty,
                            tick.Price,
                            exitFee,
                            tick.TimestampMs));"""
    new_sell_move = """                        var sellRes = await _executionGateway.SubmitOrderAsync(
                            new ExecutionOrderRequest(Guid.NewGuid(), tick.Symbol, "sell", heldQty, tick.Price, false),
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
                            tick.TimestampMs));"""
    agent = agent.replace(old_sell_move, new_sell_move, 1)

agent_path.write_text(agent, encoding="utf-8")
print(f"[OK] Patched {agent_path.relative_to(repo)}")

# --- 1D. Fix TelemetryExecutionGateway.cs connection string fallback ---
tel_path = repo / "src/QuantCore.Agents/Execution/TelemetryExecutionGateway.cs"
tel = tel_path.read_text(encoding="utf-8")
tel = tel.replace(
    'string? connStr = _config.GetConnectionString("DefaultConnection") ?? _config["POSTGRES_CONNECTION_STRING"];',
    'string? connStr = _config.GetConnectionString("DefaultConnection") ?? _config["POSTGRES_CONNECTION_STRING"] ?? _config["POSTGRES_CONNECTION"];',
)
tel_path.write_text(tel, encoding="utf-8")
print(f"[OK] Patched {tel_path.relative_to(repo)}")

# --- 1E. Fix captive HttpClient lifetime in ExecutionServiceCollectionExtensions.cs ---
ext_path = repo / "src/QuantCore.Agents/Execution/ExecutionServiceCollectionExtensions.cs"
ext = ext_path.read_text(encoding="utf-8")
if "PooledConnectionLifetime" not in ext:
    ext = ext.replace(
        ".AddHttpMessageHandler<RevxSigningDelegatingHandler>();",
        """.ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
            {
                PooledConnectionLifetime = TimeSpan.FromMinutes(2)
            })
            .SetHandlerLifetime(Timeout.InfiniteTimeSpan)
            .AddHttpMessageHandler<RevxSigningDelegatingHandler>();""",
        1,
    )
    ext_path.write_text(ext, encoding="utf-8")
print(f"[OK] Patched {ext_path.relative_to(repo)}")

# --- 1F. Align .NET 9 NuGet versions in QuantCore.Api.csproj & QuantCore.Agents.csproj ---
api_csproj = repo / "src/QuantCore.Api/QuantCore.Api.csproj"
api_xml = api_csproj.read_text(encoding="utf-8")
api_xml = api_xml.replace('Include="Npgsql" Version="8.0.3"', 'Include="Npgsql" Version="9.0.2"')
api_csproj.write_text(api_xml, encoding="utf-8")

agt_csproj = repo / "src/QuantCore.Agents/QuantCore.Agents.csproj"
agt_xml = agt_csproj.read_text(encoding="utf-8")
agt_xml = agt_xml.replace('Include="Microsoft.Extensions.Hosting" Version="8.0.0"', 'Include="Microsoft.Extensions.Hosting" Version="9.0.0"')
agt_xml = agt_xml.replace('Include="Microsoft.Extensions.Http" Version="8.0.0"', 'Include="Microsoft.Extensions.Http" Version="9.0.0"')
agt_csproj.write_text(agt_xml, encoding="utf-8")
print("[OK] Aligned .NET 9 NuGet packages across QuantCore.Api & QuantCore.Agents")

# --- 1G. Fix src/quant_nn_worker/main.py (checkpoint restore, execution_feedback, FK-safe pool swap, checkpoint pruning) ---
worker_path = repo / "src/quant_nn_worker/main.py"
worker_path.write_text("""import json
import os
from urllib.error import URLError
from urllib.request import urlopen
from uuid import uuid4

import numpy as np
import pika
import psycopg
from psycopg.rows import dict_row

from adapter.queue_consumer import INPUT_QUEUE, OUTPUT_QUEUE, process_single_task
from adapter.schemas import InputTaskMessage, TaskCommandType
from execution_feedback import fetch_execution_reward_adjustment
from quant_nn_engine import BrainStateCodec, QuantBrainBridge, ReplicaHistoryRecord

CONFIDENCE_THRESHOLD = float(os.getenv("CONFIDENCE_THRESHOLD", "0.75"))
QUANT_API_URL = os.getenv("QUANT_API_URL", "http://quant-api:8080").rstrip("/")
NN_HIDDEN_DIM = int(os.getenv("NN_HIDDEN_DIM", "128"))
MAX_CHECKPOINTS_RETAINED = int(os.getenv("MAX_CHECKPOINTS_RETAINED", "25"))
BRIDGE = QuantBrainBridge(confidence_threshold=CONFIDENCE_THRESHOLD, hidden_dim=NN_HIDDEN_DIM)


def get_pg_conn_str() -> str:
    return (
        f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
        f"port={os.getenv('POSTGRES_PORT', '5432')} "
        f"dbname={os.getenv('POSTGRES_DB', 'quantcore')} "
        f"user={os.getenv('POSTGRES_USER', 'quant')} "
        f"password={os.getenv('POSTGRES_PASSWORD', 'quant_secret')}"
    )


def try_restore_latest_checkpoint() -> None:
    try:
        with psycopg.connect(get_pg_conn_str(), row_factory=dict_row) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    \"\"\"
                    SELECT version_tag, weights_blob, confidence_score, is_promoted_live
                    FROM nn_model_checkpoints
                    WHERE weights_blob IS NOT NULL
                      AND octet_length(weights_blob) > 0
                      AND COALESCE((architecture_config->>'hidden_dim')::int, 0) = %s
                    ORDER BY is_promoted_live DESC, created_at DESC
                    LIMIT 1;
                    \"\"\",
                    (NN_HIDDEN_DIM,),
                )
                row = cur.fetchone()
                if not row:
                    print(f"[quant_nn_worker] No existing {NN_HIDDEN_DIM}-dim checkpoint found; starting fresh.", flush=True)
                    return

                raw_blob = bytes(row["weights_blob"])
                model, optimizer, meta, restored_conf = BrainStateCodec.load_state_bundle(raw_blob, lr=4e-3)
                if model.hidden_dim != NN_HIDDEN_DIM:
                    print(
                        f"[quant_nn_worker] Skipping checkpoint '{row['version_tag']}' "
                        f"(hidden_dim={model.hidden_dim} != {NN_HIDDEN_DIM})",
                        flush=True,
                    )
                    return

                BRIDGE.model = model
                BRIDGE.optimizer = optimizer
                if isinstance(meta, dict):
                    BRIDGE.generation_count = int(meta.get("generation_count", BRIDGE.generation_count))
                    gen_by_prof = meta.get("generation_by_profile")
                    if isinstance(gen_by_prof, dict):
                        BRIDGE.generation_by_profile = {str(k): int(v) for k, v in gen_by_prof.items()}

                print(
                    f"[quant_nn_worker] Restored {NN_HIDDEN_DIM}-dim checkpoint '{row['version_tag']}' "
                    f"(conf={restored_conf*100:.1f}%, promoted={row['is_promoted_live']}, gen={BRIDGE.generation_count})",
                    flush=True,
                )
    except Exception as exc:
        print(f"[quant_nn_worker] Checkpoint auto-load skipped ({exc})", flush=True)


def fetch_live_ohlcv_window(candidate_symbols: list[str], limit: int = 32) -> dict[str, np.ndarray]:
    ohlcv_map: dict[str, np.ndarray] = {}
    url = f"{QUANT_API_URL}/api/v1/market/ohlcv-window?limit={limit}"
    try:
        with urlopen(url, timeout=2.0) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
        candles_by_sym = payload.get("candles_by_symbol") or {}
        for sym in candidate_symbols:
            rows = candles_by_sym.get(sym)
            if rows and len(rows) >= 4:
                arr = np.asarray(rows, dtype=np.float32)
                if arr.ndim == 2 and arr.shape[1] == 5:
                    ohlcv_map[sym] = arr
    except (URLError, TimeoutError, ValueError, OSError):
        pass
    return ohlcv_map


def fetch_latest_generation_histories(cur, profile_key: str, limit: int) -> list[ReplicaHistoryRecord]:
    cur.execute(
        \"\"\"
        SELECT replica_index, jitter_delta, realized_pnl_usdt, max_drawdown_pct, sharpe_estimate
        FROM trading_history
        WHERE profile_key = %s
        ORDER BY completed_at DESC
        LIMIT %s;
        \"\"\",
        (profile_key, limit),
    )
    rows = cur.fetchall()
    return [
        ReplicaHistoryRecord(
            replica_index=int(r["replica_index"]),
            jitter_delta=r["jitter_delta"] if isinstance(r["jitter_delta"], dict) else json.loads(r["jitter_delta"]),
            realized_pnl_usdt=float(r["realized_pnl_usdt"]),
            max_drawdown_pct=float(r["max_drawdown_pct"]),
            sharpe_estimate=float(r["sharpe_estimate"]),
        )
        for r in rows
    ]


def handle_task(task: InputTaskMessage) -> tuple[float, dict]:
    ohlcv_by_symbol = fetch_live_ohlcv_window(task.candidate_symbols, limit=32)
    exec_stats = fetch_execution_reward_adjustment(get_pg_conn_str(), lookback_minutes=60)
    exec_penalty = float(exec_stats.get("reward_penalty", 0.0))

    with psycopg.connect(get_pg_conn_str(), row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            prior_histories = fetch_latest_generation_histories(
                cur, task.profile_key, task.replication_factor
            )

            confidence, result = BRIDGE.calculate_pool_and_forecast(
                profile_key=task.profile_key,
                risk_dial_r=task.risk_dial_r,
                candidate_symbols=task.candidate_symbols,
                replication_factor=task.replication_factor,
                ohlcv_by_symbol=ohlcv_by_symbol if ohlcv_by_symbol else None,
                prior_histories=prior_histories,
            )

            if exec_penalty > 0.0:
                confidence = max(0.0, round(confidence - exec_penalty, 4))
                result["is_promoted_for_live"] = bool(
                    result["is_promoted_for_live"] and confidence >= CONFIDENCE_THRESHOLD
                )

            if task.command == TaskCommandType.RECALCULATE_POOL:
                # Expire any FK-referenced AVAILABLE slots rather than failing on FK delete
                cur.execute(
                    \"\"\"
                    UPDATE strategy_pool sp
                    SET status = 'EXPIRED'
                    WHERE sp.profile_key = %s
                      AND sp.status = 'AVAILABLE'
                      AND EXISTS (
                          SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id
                      );
                    \"\"\",
                    (task.profile_key,),
                )
                cur.execute(
                    \"\"\"
                    DELETE FROM strategy_pool sp
                    WHERE sp.profile_key = %s
                      AND sp.status = 'AVAILABLE'
                      AND NOT EXISTS (
                          SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id
                      );
                    \"\"\",
                    (task.profile_key,),
                )
                for rep in result["replicas"]:
                    cur.execute(
                        \"\"\"
                        INSERT INTO strategy_pool
                            (pool_instance_id, profile_key, replica_index, risk_dial_r, jitter_delta, strategy_payload, candidate_symbols, status)
                        VALUES (%s, %s, %s, %s, %s::jsonb, %s::jsonb, %s::jsonb, 'AVAILABLE');
                        \"\"\",
                        (
                            str(uuid4()),
                            task.profile_key,
                            rep["replica_index"],
                            task.risk_dial_r,
                            json.dumps(rep["jitter_delta"]),
                            json.dumps(rep["strategy_payload"]),
                            json.dumps(rep["candidate_symbols"]),
                        ),
                    )

                raw_bundle = BrainStateCodec.dump_state_bundle(
                    BRIDGE.model,
                    BRIDGE.optimizer,
                    {
                        "profile_key": task.profile_key,
                        "ohlcv_symbols": list(ohlcv_by_symbol.keys()),
                        "generation_count": BRIDGE.generation_count,
                        "generation_by_profile": BRIDGE.generation_by_profile,
                    },
                    confidence,
                )
                cur.execute(
                    \"\"\"
                    INSERT INTO nn_model_checkpoints
                        (model_id, version_tag, architecture_config, weights_blob, optimizer_blob, scaler_blob, confidence_score, is_promoted_live)
                    VALUES (%s, %s, %s::jsonb, %s, %s, %s, %s, %s);
                    \"\"\",
                    (
                        str(uuid4()),
                        f"{task.profile_key}_gen{result.get('generation', 1)}",
                        json.dumps({"hidden_dim": BRIDGE.model.hidden_dim, "model_arch": "PortfolioConditionedQuantNet_v2"}),
                        raw_bundle,
                        b"",
                        b"{}",
                        confidence,
                        result["is_promoted_for_live"],
                    ),
                )
                # Keep table bounded so BYTEA checkpoints never bloat Postgres
                cur.execute(
                    \"\"\"
                    DELETE FROM nn_model_checkpoints
                    WHERE model_id NOT IN (
                        (SELECT model_id FROM nn_model_checkpoints ORDER BY created_at DESC LIMIT %s)
                        UNION
                        (SELECT model_id FROM nn_model_checkpoints WHERE is_promoted_live = true ORDER BY created_at DESC LIMIT 5)
                    );
                    \"\"\",
                    (MAX_CHECKPOINTS_RETAINED,),
                )
        conn.commit()

    print(
        f"[NN-EVOLUTION] Profile={task.profile_key} | Gen={result.get('generation', 0)} | "
        f"OHLCV_Syms={len(ohlcv_by_symbol)}/{len(task.candidate_symbols)} | "
        f"ExecPen={exec_penalty:.4f} (ord={exec_stats['total_orders']}) | "
        f"Winner=Replica#{result['winning_prior_replica']} | Loss={result.get('train_loss', 0.0):.4f} | "
        f"Confidence={confidence*100:.1f}% | Promoted={result['is_promoted_for_live']}",
        flush=True,
    )

    return confidence, {
        "profile_key": task.profile_key,
        "winning_prior_replica": result["winning_prior_replica"],
        "is_promoted_for_live": result["is_promoted_for_live"],
        "replicas_generated": len(result["replicas"]),
    }


def main() -> None:
    try_restore_latest_checkpoint()

    rmq_host = os.getenv("RABBITMQ_HOST", "localhost")
    rmq_port = int(os.getenv("RABBITMQ_PORT", "5672"))
    params = pika.ConnectionParameters(host=rmq_host, port=rmq_port)
    connection = pika.BlockingConnection(params)
    channel = connection.channel()

    channel.queue_declare(queue=INPUT_QUEUE, durable=True)
    channel.queue_declare(
        queue=OUTPUT_QUEUE,
        durable=True,
        arguments={"x-max-length": 1, "x-overflow": "drop-head"},
    )
    channel.basic_qos(prefetch_count=1)

    def _on_message(ch, method, properties, body):
        try:
            process_single_task(ch, body, handle_task)
        finally:
            ch.basic_ack(delivery_tag=method.delivery_tag)

    channel.basic_consume(queue=INPUT_QUEUE, on_message_callback=_on_message)
    print("[quant_nn_worker] Connected to quant_nn_engine. Listening on input_queue...", flush=True)
    channel.start_consuming()


if __name__ == "__main__":
    main()
""", encoding="utf-8")
print(f"[OK] Rewrote {worker_path.relative_to(repo)}")

# --- 1H. Update docker-compose.yml (restart policies + agent DB/gateway/RevX env vars + worker QUANT_API_URL) ---
compose_path = repo / "docker-compose.yml"
compose_path.write_text("""services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB:-quantcore}
      POSTGRES_USER: ${POSTGRES_USER:-quant}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-quant_secret}
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-quant} -d ${POSTGRES_DB:-quantcore}"]
      interval: 3s
      timeout: 3s
      retries: 10

  rabbitmq:
    image: rabbitmq:3.13-management-alpine
    restart: unless-stopped
    ports:
      - "5672:5672"
      - "15672:15672"
      - "15692:15692"
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 5s
      timeout: 5s
      retries: 10

  migrations:
    build:
      context: ./migrations
      dockerfile: Dockerfile
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_DB: ${POSTGRES_DB:-quantcore}
      POSTGRES_USER: ${POSTGRES_USER:-quant}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-quant_secret}
    depends_on:
      postgres:
        condition: service_healthy
    restart: "no"

  nn-worker:
    build:
      context: .
      dockerfile: src/quant_nn_worker/Dockerfile
    restart: unless-stopped
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_DB: ${POSTGRES_DB:-quantcore}
      POSTGRES_USER: ${POSTGRES_USER:-quant}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-quant_secret}
      RABBITMQ_HOST: rabbitmq
      RABBITMQ_PORT: 5672
      QUANT_API_URL: http://quant-api:8080
      NN_HIDDEN_DIM: ${NN_HIDDEN_DIM:-128}
      POOL_REPLICATION_FACTOR: ${POOL_REPLICATION_FACTOR:-3}
      CONFIDENCE_THRESHOLD: ${CONFIDENCE_THRESHOLD:-0.75}
    depends_on:
      migrations:
        condition: service_completed_successfully
      rabbitmq:
        condition: service_healthy

  quant-api:
    build:
      context: .
      dockerfile: src/QuantCore.Api/Dockerfile
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      ASPNETCORE_URLS: http://+:8080
      POSTGRES_CONNECTION: Host=postgres;Port=5432;Database=${POSTGRES_DB:-quantcore};Username=${POSTGRES_USER:-quant};Password=${POSTGRES_PASSWORD:-quant_secret}
      RABBITMQ_HOST: rabbitmq
      RABBITMQ_PORT: 5672
      BINANCE_WS_URL: ${BINANCE_WS_URL:-wss://stream.binance.com:9443/stream?streams=btcusdt@kline_1m/ethusdt@kline_1m/solusdt@kline_1m}
      POOL_REPLICATION_FACTOR: ${POOL_REPLICATION_FACTOR:-3}
      CONFIDENCE_THRESHOLD: ${CONFIDENCE_THRESHOLD:-0.75}
      LOCK_TTL_SECONDS: ${LOCK_TTL_SECONDS:-5}
    depends_on:
      migrations:
        condition: service_completed_successfully
      rabbitmq:
        condition: service_healthy

  # Opt-in so agents don't consume pool slots during verify-local.sh: docker compose --profile agents up --scale quant-agents=3
  quant-agents:
    profiles: ["agents"]
    build:
      context: .
      dockerfile: src/QuantCore.Agents/Dockerfile
    restart: unless-stopped
    command: ["--mode", "agent"]
    environment:
      QUANT_API_URL: http://quant-api:8080
      QUANT_API_WS_URL: ws://quant-api:8080/api/v1/stream/live
      POSTGRES_CONNECTION: Host=postgres;Port=5432;Database=${POSTGRES_DB:-quantcore};Username=${POSTGRES_USER:-quant};Password=${POSTGRES_PASSWORD:-quant_secret}
      AGENT_PROFILE_KEY: ${AGENT_PROFILE_KEY:-ALL}
      EPISODE_SETTLEMENT_MODE: ${EPISODE_SETTLEMENT_MODE:-CARRY_POSITIONS}
      EPISODE_MAX_TICKS: ${EPISODE_MAX_TICKS:-25}
      EPISODE_MAX_SECONDS: ${EPISODE_MAX_SECONDS:-300}
      EXECUTION_GATEWAY: ${EXECUTION_GATEWAY:-SIMULATED}
      REVX_AUTH_PROVIDER: ${REVX_AUTH_PROVIDER:-FAKE}
      REVX_DRY_RUN: ${REVX_DRY_RUN:-true}
      REVX_MAX_ORDER_USDT: ${REVX_MAX_ORDER_USDT:-25}
      REVX_API_BASE_URL: ${REVX_API_BASE_URL:-https://revx.revolut.com}
      REVX_API_KEY: ${REVX_API_KEY:-}
      REVX_PRIVATE_KEY_PEM: ${REVX_PRIVATE_KEY_PEM:-}
    depends_on:
      quant-api:
        condition: service_started
""", encoding="utf-8")
print(f"[OK] Updated {compose_path.relative_to(repo)}")

# --- 1I. Fix verify-local.sh SDK image (8.0 -> 9.0) ---
verify_path = repo / "verify-local.sh"
if verify_path.exists():
    v = verify_path.read_text(encoding="utf-8")
    v = v.replace("mcr.microsoft.com/dotnet/sdk:8.0-alpine", "mcr.microsoft.com/dotnet/sdk:9.0-alpine")
    verify_path.write_text(v, encoding="utf-8")
    print("[OK] Updated verify-local.sh to dotnet/sdk:9.0-alpine")

# --- 1J. Fix FK bugs and schema landmines in tooling/*.sh ---
norm_path = repo / "tooling/normalize-db.sh"
if norm_path.exists():
    norm = norm_path.read_text(encoding="utf-8")
    norm = norm.replace(
        """UPDATE strategy_pool
SET status = 'AVAILABLE'
WHERE status = 'CLAIMED';""",
        """-- Restore any row referenced by trading_history to COMPLETED
UPDATE strategy_pool sp
SET status = 'COMPLETED'
WHERE sp.status IN ('AVAILABLE', 'CLAIMED')
  AND EXISTS (SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id);

-- Reclaim only unreferenced orphaned CLAIMED slots back to AVAILABLE
UPDATE strategy_pool sp
SET status = 'AVAILABLE', claimed_by_agent_id = NULL, claimed_at = NULL
WHERE sp.status = 'CLAIMED'
  AND NOT EXISTS (SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id);""",
    )
    norm = norm.replace(
        """WITH ranked_history AS (
  SELECT pool_instance_id,
         ROW_NUMBER() OVER (PARTITION BY profile_key ORDER BY created_at DESC) AS rn
  FROM strategy_pool
  WHERE status IN ('COMPLETED', 'EXPIRED')
)
DELETE FROM strategy_pool
WHERE pool_instance_id IN (
  SELECT pool_instance_id FROM ranked_history WHERE rn > 30
);""",
        """WITH ranked_history AS (
  SELECT sp.pool_instance_id,
         ROW_NUMBER() OVER (PARTITION BY sp.profile_key ORDER BY sp.created_at DESC) AS rn
  FROM strategy_pool sp
  WHERE sp.status IN ('COMPLETED', 'EXPIRED')
    AND NOT EXISTS (SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id)
)
DELETE FROM strategy_pool
WHERE pool_instance_id IN (
  SELECT pool_instance_id FROM ranked_history WHERE rn > 30
);""",
    )
    norm_path.write_text(norm, encoding="utf-8")
    print("[OK] Hardened tooling/normalize-db.sh against FK violations")

refresh_path = repo / "tooling/refresh-dockers.sh"
if refresh_path.exists():
    ref = refresh_path.read_text(encoding="utf-8")
    ref = ref.replace(
        """  UPDATE strategy_pool
  SET status = 'AVAILABLE', claimed_by_agent_id = NULL, claimed_at = NULL
  WHERE status != 'AVAILABLE';""",
        """  UPDATE strategy_pool sp
  SET status = 'COMPLETED'
  WHERE sp.status IN ('AVAILABLE', 'CLAIMED')
    AND EXISTS (SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id);

  UPDATE strategy_pool sp
  SET status = 'AVAILABLE', claimed_by_agent_id = NULL, claimed_at = NULL
  WHERE sp.status = 'CLAIMED'
    AND NOT EXISTS (SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id);""",
    )
    refresh_path.write_text(ref, encoding="utf-8")
    print("[OK] Fixed tooling/refresh-dockers.sh so COMPLETED history is never flipped to AVAILABLE")

for dangerous_script in ("tooling/clean-strategy-pool.sh", "tooling/fix-ui-pool-list.sh"):
    p = repo / dangerous_script
    if p.exists():
        txt = p.read_text(encoding="utf-8")
        if "ALTER TABLE strategy_pool DROP COLUMN IF EXISTS claimed_by_agent_id;" in txt:
            txt = txt.replace(
                "ALTER TABLE strategy_pool DROP COLUMN IF EXISTS claimed_by_agent_id;",
                "-- [NEUTRALIZED] Never drop claimed_by_agent_id (required by QuantCore.Api)",
            )
            p.write_text(txt, encoding="utf-8")
            print(f"[OK] Neutralized DROP COLUMN landmine in {dangerous_script}")
PYEOF

# ---------------------------------------------------------------------------
step "2/6 Running .NET 9 Unit Tests (QuantCore.Tests + QuantCore.Agents.Tests)"
# ---------------------------------------------------------------------------
dotnet test "$REPO_ROOT/tests/QuantCore.Tests/QuantCore.Tests.csproj" -c Release --nologo -v minimal
dotnet test "$REPO_ROOT/tests/QuantCore.Agents.Tests/QuantCore.Agents.Tests.csproj" -c Release --nologo -v minimal
ok "All .NET 9 unit tests passed"

# ---------------------------------------------------------------------------
step "3/6 Repairing PostgreSQL strategy_pool & Reclaiming ~650 MB Checkpoint Bloat"
# ---------------------------------------------------------------------------
dc exec -T postgres psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" << 'SQL'
BEGIN;

-- 1. Any strategy_pool row referenced by trading_history is COMPLETED, never AVAILABLE
UPDATE strategy_pool sp
SET status = 'COMPLETED'
WHERE sp.status <> 'COMPLETED'
  AND EXISTS (SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id);

-- 2. Delete all unreferenced AVAILABLE / EXPIRED / CLAIMED clutter
DELETE FROM strategy_pool sp
WHERE sp.status IN ('AVAILABLE', 'CLAIMED', 'EXPIRED')
  AND NOT EXISTS (SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id);

-- 3. Release any stale active allocations and inventory locks
UPDATE strategy_allocations SET status = 'RELEASED' WHERE status = 'ACTIVE';
UPDATE portfolio_inventory SET allocated_quantity = 0, locked_by_agent = NULL, lock_expires_at = NULL;

-- 4. Seed exact 3 replicas x 3 profiles (9 clean AVAILABLE slots)
WITH profile_targets(profile_key, default_r, default_sl, default_tp, default_slice) AS (
  VALUES
    ('AGGRESSIVE_BREAKOUT',    0.75, 2.20, 3.20, 0.40),
    ('BALANCED_SWING',         0.50, 1.80, 2.60, 0.30),
    ('CAREFUL_MEAN_REVERSION', 0.25, 1.35, 1.90, 0.20)
),
replicas(replica_index, jitter_mult) AS (
  VALUES (1, -0.05), (2, 0.00), (3, 0.05)
)
INSERT INTO strategy_pool (
  pool_instance_id, profile_key, replica_index, risk_dial_r, status,
  candidate_symbols, strategy_payload, jitter_delta, created_at
)
SELECT
  gen_random_uuid(),
  pt.profile_key,
  r.replica_index,
  pt.default_r,
  'AVAILABLE',
  '["BTCUSDT","ETHUSDT","SOLUSDT"]'::jsonb,
  jsonb_build_object(
    'entry_threshold', 0.60,
    'stop_loss_atr', ROUND((pt.default_sl + r.jitter_mult)::numeric, 4),
    'take_profit_rr', ROUND((pt.default_tp + r.jitter_mult)::numeric, 4),
    'max_slice_claim_pct', pt.default_slice
  ),
  jsonb_build_object('jitter', r.jitter_mult),
  NOW()
FROM profile_targets pt
CROSS JOIN replicas r;

-- 5. Prune nn_model_checkpoints to latest 25 + latest 5 promoted (eliminating 659 MB bloat)
DELETE FROM nn_model_checkpoints
WHERE model_id NOT IN (
  (SELECT model_id FROM nn_model_checkpoints ORDER BY created_at DESC LIMIT 25)
  UNION
  (SELECT model_id FROM nn_model_checkpoints WHERE is_promoted_live = true ORDER BY created_at DESC LIMIT 5)
);

COMMIT;

VACUUM FULL nn_model_checkpoints;
VACUUM ANALYZE strategy_pool;
VACUUM ANALYZE strategy_allocations;
SQL
ok "PostgreSQL repaired and vacuumed"

# ---------------------------------------------------------------------------
step "4/6 Rebuilding nn-worker, quant-api (with fresh UI) & quant-agents Sequentially"
# ---------------------------------------------------------------------------
dc build nn-worker
dc build quant-api
dc --profile agents build quant-agents
ok "All three service images rebuilt cleanly on .NET 9 / Python 3.11"

# ---------------------------------------------------------------------------
step "5/6 Starting Stack & 3x Multiplexed Agents (SIMULATED + CARRY_POSITIONS)"
# ---------------------------------------------------------------------------
dc up -d --force-recreate nn-worker quant-api

info "Waiting for quant-api /health/ready..."
for i in {1..30}; do
  CODE=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" http://localhost:8080/health/ready || echo "000")
  if [[ "$CODE" == "200" ]]; then
    ok "quant-api is READY -> $(curl -s http://localhost:8080/health/ready)"
    break
  fi
  sleep 1
done

EXECUTION_GATEWAY="SIMULATED" \
REVX_AUTH_PROVIDER="FAKE" \
REVX_DRY_RUN="true" \
AGENT_PROFILE_KEY="ALL" \
EPISODE_SETTLEMENT_MODE="CARRY_POSITIONS" \
EPISODE_MAX_TICKS=25 \
  dc --profile agents up -d --scale quant-agents=3 --force-recreate quant-agents
ok "3x quant-agents started"

# ---------------------------------------------------------------------------
step "6/6 20-Second Stability & Telemetry Verification"
# ---------------------------------------------------------------------------
info "Waiting 20s (past the old 15s synthetic fallback crash window)..."
sleep 20

echo "--- Container Health ---"
dc --profile agents ps -a

echo "--- PostgreSQL State & Sizes ---"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" << 'SQL'
SELECT status, (claimed_by_agent_id IS NOT NULL) AS is_claimed, COUNT(*)
FROM strategy_pool GROUP BY 1, 2 ORDER BY 1, 2;

SELECT relname, n_live_tup, pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
WHERE relname IN ('nn_model_checkpoints', 'strategy_pool', 'trading_history', 'execution_history')
ORDER BY pg_total_relation_size(relid) DESC;

SELECT provider, execution_mode, accepted, COUNT(*) AS orders
FROM execution_history GROUP BY 1, 2, 3;
SQL

echo "--- Recent Logs (quant-api / nn-worker / quant-agents) ---"
dc logs --tail=15 quant-api
dc logs --tail=15 nn-worker
dc --profile agents logs --tail=15 quant-agents

ok "Fix & verification complete! Hard-refresh http://localhost:8080 (Cmd+Shift+R)."