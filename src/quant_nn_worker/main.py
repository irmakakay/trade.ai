import json
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
                    """
                    SELECT version_tag, weights_blob, confidence_score, is_promoted_live
                    FROM nn_model_checkpoints
                    WHERE weights_blob IS NOT NULL
                      AND octet_length(weights_blob) > 0
                      AND COALESCE((architecture_config->>'hidden_dim')::int, 0) = %s
                    ORDER BY is_promoted_live DESC, created_at DESC
                    LIMIT 1;
                    """,
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
        """
        SELECT replica_index, jitter_delta, realized_pnl_usdt, max_drawdown_pct, sharpe_estimate
        FROM trading_history
        WHERE profile_key = %s
        ORDER BY completed_at DESC
        LIMIT %s;
        """,
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
                    """
                    UPDATE strategy_pool sp
                    SET status = 'EXPIRED'
                    WHERE sp.profile_key = %s
                      AND sp.status = 'AVAILABLE'
                      AND EXISTS (
                          SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id
                      );
                    """,
                    (task.profile_key,),
                )
                cur.execute(
                    """
                    DELETE FROM strategy_pool sp
                    WHERE sp.profile_key = %s
                      AND sp.status = 'AVAILABLE'
                      AND NOT EXISTS (
                          SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id
                      );
                    """,
                    (task.profile_key,),
                )
                for rep in result["replicas"]:
                    cur.execute(
                        """
                        INSERT INTO strategy_pool
                            (pool_instance_id, profile_key, replica_index, risk_dial_r, jitter_delta, strategy_payload, candidate_symbols, status)
                        VALUES (%s, %s, %s, %s, %s::jsonb, %s::jsonb, %s::jsonb, 'AVAILABLE');
                        """,
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
                    """
                    INSERT INTO nn_model_checkpoints
                        (model_id, version_tag, architecture_config, weights_blob, optimizer_blob, scaler_blob, confidence_score, is_promoted_live)
                    VALUES (%s, %s, %s::jsonb, %s, %s, %s, %s, %s);
                    """,
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
                    """
                    DELETE FROM nn_model_checkpoints
                    WHERE model_id NOT IN (
                        (SELECT model_id FROM nn_model_checkpoints ORDER BY created_at DESC LIMIT %s)
                        UNION
                        (SELECT model_id FROM nn_model_checkpoints WHERE is_promoted_live = true ORDER BY created_at DESC LIMIT 5)
                    );
                    """,
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
