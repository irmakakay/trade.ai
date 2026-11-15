import json
import os
from uuid import uuid4
import pika
import psycopg
import torch
from adapter.queue_consumer import INPUT_QUEUE, OUTPUT_QUEUE, process_single_task
from adapter.schemas import InputTaskMessage, TaskCommandType
from brain.engine import StrategyConditionedNet, generate_epsilon_jittered_pool

def get_pg_conn_str() -> str:
    return (
        f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
        f"port={os.getenv('POSTGRES_PORT', '5432')} "
        f"dbname={os.getenv('POSTGRES_DB', 'quantcore')} "
        f"user={os.getenv('POSTGRES_USER', 'quant')} "
        f"password={os.getenv('POSTGRES_PASSWORD', 'quant_secret')}"
    )

def handle_task(task: InputTaskMessage) -> tuple[float, dict]:
    net = StrategyConditionedNet()
    dummy_features = torch.zeros((1, 16), dtype=torch.float32)
    base_strat = net(dummy_features, task.risk_dial_r)
    replicas = generate_epsilon_jittered_pool(
        base_strat,
        task.candidate_symbols,
        task.replication_factor,
    )

    if task.command == TaskCommandType.RECALCULATE_POOL:
        with psycopg.connect(get_pg_conn_str()) as conn:
            with conn.cursor() as cur:
                for rep in replicas:
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
            conn.commit()

    return 0.82, {"profile_key": task.profile_key, "replicas_generated": len(replicas)}

def main() -> None:
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
    print("[quant_nn_worker] Listening on input_queue...")
    channel.start_consuming()

if __name__ == "__main__":
    main()
