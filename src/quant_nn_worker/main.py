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
                    """
                    SELECT version_tag, weights_blob, confidence_score, is_promoted_live
                    FROM nn_model_checkpoints
                    WHERE weights_blob IS NOT NULL AND octet_length(weights_blob) > 0
                    ORDER BY is_promoted_live DESC, confidence_score DESC, created_at DESC
                    LIMIT 1;
                    """
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
                    {"profile_key": task.profile_key, "ohlcv_symbols": list(ohlcv_by_symbol.keys())},
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
