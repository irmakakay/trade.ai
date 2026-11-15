import json
from datetime import datetime, timezone
from typing import Callable
from uuid import UUID
from adapter.schemas import InputTaskMessage, OutputStatusMessage, QueueJobState

INPUT_QUEUE = "input_queue"
OUTPUT_QUEUE = "output_queue"

class SingleSlotStatusPublisher:
    def __init__(self, channel):
        self.channel = channel

    def push_status(
        self,
        job_id: UUID,
        status: QueueJobState,
        progress_pct: float,
        confidence_score: float,
        result_payload: str | None = None,
        error_message: str | None = None,
    ) -> None:
        msg = OutputStatusMessage(
            job_id=job_id,
            status=status,
            progress_pct=progress_pct,
            confidence_score=confidence_score,
            result_payload=result_payload,
            error_message=error_message,
            updated_at_utc=datetime.now(timezone.utc),
        )
        body = msg.model_dump_json().encode("utf-8")
        self.channel.basic_publish(exchange="", routing_key=OUTPUT_QUEUE, body=body)

        # Fallback: if consumer mid-peek caused queue size to hit 0 on terminal status, re-push once
        if status in (QueueJobState.SUCCEEDED, QueueJobState.FAILED):
            q_state = self.channel.queue_declare(
                queue=OUTPUT_QUEUE,
                durable=True,
                passive=True,
            )
            if q_state.method.message_count == 0:
                self.channel.basic_publish(exchange="", routing_key=OUTPUT_QUEUE, body=body)

def process_single_task(channel, raw_body: bytes, handler: Callable[[InputTaskMessage], tuple[float, dict]]) -> None:
    task = InputTaskMessage.model_validate_json(raw_body)
    publisher = SingleSlotStatusPublisher(channel)
    try:
        publisher.push_status(task.job_id, QueueJobState.PROCESSING, 50.0, 0.0)
        confidence, result_dict = handler(task)
        publisher.push_status(
            task.job_id,
            QueueJobState.SUCCEEDED,
            100.0,
            confidence,
            result_payload=json.dumps(result_dict),
        )
    except Exception as exc:
        publisher.push_status(
            task.job_id,
            QueueJobState.FAILED,
            100.0,
            0.0,
            error_message=str(exc),
        )
        raise
