import json
from uuid import uuid4
import torch
from adapter.checkpoint_store import PostgresCheckpointStore
from adapter.queue_consumer import process_single_task
from adapter.schemas import InputTaskMessage, TaskCommandType

class FakeQueueMethod:
    def __init__(self, count: int):
        self.message_count = count

class FakeDeclareResult:
    def __init__(self, count: int):
        self.method = FakeQueueMethod(count)

class FakeChannel:
    def __init__(self, simulate_empty_on_terminal: bool = False):
        self.published = []
        self.simulate_empty_on_terminal = simulate_empty_on_terminal

    def basic_publish(self, exchange, routing_key, body):
        self.published.append((routing_key, json.loads(body.decode("utf-8"))))

    def queue_declare(self, queue, durable, passive):
        return FakeDeclareResult(0 if self.simulate_empty_on_terminal else 1)

def test_queue_consumer_re_pushes_terminal_status_when_queue_size_is_zero():
    ch = FakeChannel(simulate_empty_on_terminal=True)
    task_json = json.dumps({
        "job_id": str(uuid4()),
        "command": "RECALCULATE_POOL",
        "profile_key": "AGGRESSIVE_BREAKOUT",
        "risk_dial_r": 0.85,
        "replication_factor": 3,
        "candidate_symbols": ["SOLUSDT"],
        "submitted_at_utc": "2026-11-14T20:00:00Z"
    }).encode("utf-8")

    process_single_task(ch, task_json, lambda t: (0.88, {"status": "ok"}))
    # 1st push: PROCESSING, 2nd push: SUCCEEDED, 3rd push: fallback SUCCEEDED because message_count == 0
    assert len(ch.published) == 3
    assert ch.published[0][1]["status"] == "PROCESSING"
    assert ch.published[1][1]["status"] == "SUCCEEDED"
    assert ch.published[2][1]["status"] == "SUCCEEDED"

def test_checkpoint_store_bytea_roundtrip():
    model1 = torch.nn.Linear(4, 2)
    opt1 = torch.optim.AdamW(model1.parameters(), lr=0.001)
    scaler = {"BTCUSDT": {"mean": 65000.0, "std": 1200.0}}

    w_bytes, o_bytes, s_bytes = PostgresCheckpointStore.serialize_to_bytes(model1, opt1, scaler)

    model2 = torch.nn.Linear(4, 2)
    opt2 = torch.optim.AdamW(model2.parameters(), lr=0.001)
    restored_scaler = PostgresCheckpointStore.deserialize_from_bytes(model2, opt2, w_bytes, o_bytes, s_bytes)

    assert restored_scaler == scaler
    assert torch.allclose(model1.weight, model2.weight)
