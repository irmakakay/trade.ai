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

run_guarded() {
  local timeout_sec="$1"
  local label="$2"
  shift 2

  info "Running: ${label} (timeout: ${timeout_sec}s)..."
  local log_file="/tmp/quant_ohlcv_$$.log"
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

step "1/4 Adding Rolling 32-Candle Ring Buffer to MarketStreamGateway & BinanceMarketFeedHostedService"

python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()

# 1. Extend MarketStreamGateway.cs with thread-safe per-symbol 32-candle OHLCV window
gw_path = repo_root / "src/QuantCore.Api/Services/MarketStreamGateway.cs"
gw_code = gw_path.read_text(encoding="utf-8")

if "RecordOhlcvCandle" not in gw_code:
    gw_code = gw_code.replace(
        "private readonly ConcurrentQueue<LiveStreamFrame> _recentEvents = new();",
        """private readonly ConcurrentQueue<LiveStreamFrame> _recentEvents = new();
    private readonly ConcurrentDictionary<string, List<double[]>> _ohlcvBySymbol = new();
    private readonly object _ohlcvLock = new();
    private const int MaxCandleWindow = 32;"""
    )

    gw_code = gw_code.replace(
        "public IReadOnlyDictionary<string, decimal> LatestPrices => _latestPrices;",
        """public IReadOnlyDictionary<string, decimal> LatestPrices => _latestPrices;

    public void RecordOhlcvCandle(string symbol, double open, double high, double low, double close, double volume)
    {
        if (string.IsNullOrWhiteSpace(symbol) || close <= 0.0) return;
        lock (_ohlcvLock)
        {
            if (!_ohlcvBySymbol.TryGetValue(symbol, out var list))
            {
                list = new List<double[]>(MaxCandleWindow + 1);
                _ohlcvBySymbol[symbol] = list;
            }
            list.Add(new[] { open, high, low, close, volume });
            while (list.Count > MaxCandleWindow)
            {
                list.RemoveAt(0);
            }
        }
    }

    public Dictionary<string, double[][]> GetOhlcvSnapshot(int limit = MaxCandleWindow)
    {
        int clamped = Math.Clamp(limit, 1, MaxCandleWindow);
        var snap = new Dictionary<string, double[][]>(StringComparer.OrdinalIgnoreCase);
        lock (_ohlcvLock)
        {
            foreach (var (sym, list) in _ohlcvBySymbol)
            {
                int take = Math.Min(clamped, list.Count);
                var arr = new double[take][];
                for (int i = 0; i < take; i++)
                {
                    var src = list[list.Count - take + i];
                    arr[i] = new[] { src[0], src[1], src[2], src[3], src[4] };
                }
                snap[sym] = arr;
            }
        }
        return snap;
    }"""
    )

    gw_code = gw_code.replace(
        "if (frame.EventType == \"MARKET_TICK\" && frame.Price > 0m)\n        {\n            _latestPrices[frame.Symbol] = frame.Price;\n        }",
        """if (frame.EventType == "MARKET_TICK" && frame.Price > 0m)
        {
            _latestPrices[frame.Symbol] = frame.Price;
            double p = (double)frame.Price;
            RecordOhlcvCandle(frame.Symbol, p, p * 1.0005, p * 0.9995, p, 1.0);
        }"""
    )

    gw_path.write_text(gw_code, encoding="utf-8")
    print(f"[OK] Updated {gw_path} with rolling 32-candle OHLCV snapshot")

# 2. Record true kline OHLCV + volume in BinanceMarketFeedHostedService.cs
feed_path = repo_root / "src/QuantCore.Api/Services/BinanceMarketFeedHostedService.cs"
feed_code = feed_path.read_text(encoding="utf-8")

if "RecordOhlcvCandle" not in feed_code:
    feed_code = feed_code.replace(
        "if (TryParseBinanceKline(buffer.AsSpan(0, res.Count), out var frame))\n                    {\n                        _gateway.PublishFrame(frame);\n                    }",
        """if (TryParseBinanceKlineWithOhlcv(buffer.AsSpan(0, res.Count), out var frame, out var candle))
                    {
                        if (candle is not null)
                        {
                            _gateway.RecordOhlcvCandle(frame.Symbol, candle[0], candle[1], candle[2], candle[3], candle[4]);
                        }
                        _gateway.PublishFrame(frame);
                    }"""
    )

    helper_method = """
    public static bool TryParseBinanceKlineWithOhlcv(
        ReadOnlySpan<byte> utf8Json,
        out LiveStreamFrame frame,
        out double[]? ohlcv)
    {
        ohlcv = null;
        if (!TryParseBinanceKline(utf8Json, out frame))
            return false;

        try
        {
            using var doc = JsonDocument.Parse(utf8Json.ToArray());
            var root = doc.RootElement;
            var payload = root.TryGetProperty("data", out var dataElem) ? dataElem : root;
            if (payload.TryGetProperty("k", out var kline))
            {
                double c = (double)frame.Price;
                double o = kline.TryGetProperty("o", out var op) && double.TryParse(op.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var ov) ? ov : c;
                double h = kline.TryGetProperty("h", out var hp) && double.TryParse(hp.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var hv) ? hv : Math.Max(o, c);
                double l = kline.TryGetProperty("l", out var lp) && double.TryParse(lp.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var lv) ? lv : Math.Min(o, c);
                double v = kline.TryGetProperty("v", out var vp) && double.TryParse(vp.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var vv) ? vv : 1.0;
                ohlcv = new[] { o, h, l, c, v };
            }
        }
        catch
        {
            // Keep frame even if optional OHLCV fields are absent
        }
        return true;
    }
"""
    feed_code = feed_code.replace(
        "    public static bool TryParseBinanceKline(",
        helper_method + "\n    public static bool TryParseBinanceKline("
    )
    feed_path.write_text(feed_code, encoding="utf-8")
    print(f"[OK] Updated {feed_path} with kline OHLCV extraction")

# 3. Expose GET /api/v1/market/ohlcv-window in AgentEpisodeEndpoints.cs
ep_path = repo_root / "src/QuantCore.Api/Endpoints/AgentEpisodeEndpoints.cs"
ep_code = ep_path.read_text(encoding="utf-8")

if "/api/v1/market/ohlcv-window" not in ep_code:
    endpoint_snippet = """        app.MapGet("/api/v1/market/ohlcv-window", (int? limit, MarketStreamGateway stream) =>
        {
            var snapshot = stream.GetOhlcvSnapshot(limit ?? 32);
            return Results.Ok(new { candles_by_symbol = snapshot });
        });

        return app;"""
    ep_code = ep_code.replace("\n        return app;", "\n" + endpoint_snippet)
    ep_path.write_text(ep_code, encoding="utf-8")
    print(f"[OK] Added /api/v1/market/ohlcv-window endpoint to {ep_path}")
PYEOF

step "2/4 Wiring Live 32-Candle OHLCV Injection, Startup Checkpoint Auto-Load & OOS Gate in Python"

python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()

# Update bridge.py to enforce out-of-sample promotion criteria (confidence + positive Sharpe / fitness)
bridge_path = repo_root / "src/quant_nn_engine/bridge.py"
bridge_code = bridge_path.read_text(encoding="utf-8")

old_promo = "is_promoted_for_live=(confidence >= self.confidence_threshold and (not prior_histories or max(h.sharpe_estimate for h in prior_histories) > 0.0)),"
new_promo = """is_promoted_for_live=(
                confidence >= self.confidence_threshold
                and (
                    not prior_histories
                    or (
                        (sum(h.sharpe_estimate for h in prior_histories) / len(prior_histories)) >= 0.0
                        and max(h.sharpe_estimate for h in prior_histories) > 0.20
                    )
                )
            ),"""

if old_promo in bridge_code:
    bridge_code = bridge_code.replace(old_promo, new_promo)
    bridge_path.write_text(bridge_code, encoding="utf-8")
    print(f"[OK] Hardened out-of-sample promotion gate in {bridge_path}")

# Update src/quant_nn_worker/main.py to:
#  1. Restore latest promoted/best BYTEA checkpoint on startup via BrainStateCodec
#  2. Fetch live rolling 32-candle OHLCV window from quant-api (/api/v1/market/ohlcv-window)
#  3. Pass ohlcv_by_symbol into BRIDGE.calculate_pool_and_forecast()
worker_path = repo_root / "src/quant_nn_worker/main.py"
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
from quant_nn_engine import BrainStateCodec, QuantBrainBridge, ReplicaHistoryRecord

CONFIDENCE_THRESHOLD = float(os.getenv("CONFIDENCE_THRESHOLD", "0.75"))
QUANT_API_URL = os.getenv("QUANT_API_URL", "http://quant-api:8080").rstrip("/")
BRIDGE = QuantBrainBridge(confidence_threshold=CONFIDENCE_THRESHOLD, hidden_dim=64)


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
                    WHERE weights_blob IS NOT NULL AND octet_length(weights_blob) > 0
                    ORDER BY is_promoted_live DESC, confidence_score DESC, created_at DESC
                    LIMIT 1;
                    \"\"\"
                )
                row = cur.fetchone()
                if not row:
                    return
                raw_blob = bytes(row["weights_blob"])
                meta = BrainStateCodec.load_state_bundle(raw_blob, BRIDGE.model, BRIDGE.optimizer)
                print(
                    f"[quant_nn_worker] Restored checkpoint '{row['version_tag']}' "
                    f"(conf={float(row['confidence_score'])*100:.1f}%, promoted={row['is_promoted_live']}, meta={meta})",
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

            if task.command == TaskCommandType.RECALCULATE_POOL:
                cur.execute(
                    "DELETE FROM strategy_pool WHERE profile_key = %s AND status = 'AVAILABLE';",
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
                    {"profile_key": task.profile_key, "ohlcv_symbols": list(ohlcv_by_symbol.keys())},
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
                        json.dumps({"hidden_dim": BRIDGE.model.hidden_dim}),
                        raw_bundle,
                        b"",
                        b"{}",
                        confidence,
                        result["is_promoted_for_live"],
                    ),
                )
        conn.commit()

    print(
        f"[NN-EVOLUTION] Profile={task.profile_key} | Gen={result.get('generation', 0)} | "
        f"OHLCV_Syms={len(ohlcv_by_symbol)}/{len(task.candidate_symbols)} | "
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
    print("[quant_nn_worker] Connected to quant_nn_engine. Listening on input_queue...")
    channel.start_consuming()


if __name__ == "__main__":
    main()
""", encoding="utf-8")
print(f"[OK] Updated {worker_path} with checkpoint auto-reload & live 32-candle OHLCV injection")
PYEOF

step "3/4 Rebuilding & Restarting quant-api and nn-worker"
run_guarded 240 "Building quant-api image" dc build quant-api
run_guarded 240 "Building nn-worker image" dc build nn-worker
run_guarded 30 "Restarting quant-api and nn-worker" dc up -d --no-deps quant-api nn-worker

step "4/4 Normalizing DB & Starting 3x Multiplexed CARRY_POSITIONS Agents"
if [[ -x "$REPO_ROOT/tooling/normalize-db.sh" ]]; then
  "$REPO_ROOT/tooling/normalize-db.sh"
fi

AGENT_PROFILE_KEY="ALL" \
EPISODE_SETTLEMENT_MODE="CARRY_POSITIONS" \
EPISODE_MAX_TICKS=25 \
  run_guarded 45 "Starting 3 quant-agents replicas" \
  dc --profile agents up -d --scale quant-agents=3 --force-recreate quant-agents

ok "Upgrade complete (#1 Live OHLCV Window + #3 Checkpoint Auto-Reload & OOS Gate)! Streaming logs:"
dc --profile agents logs -f --tail=20 nn-worker quant-agents