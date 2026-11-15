from datetime import datetime
from enum import Enum
from typing import List, Optional
from uuid import UUID
from pydantic import BaseModel, Field

class TaskCommandType(str, Enum):
    TRAIN_HISTORICAL = "TRAIN_HISTORICAL"
    RECALCULATE_POOL = "RECALCULATE_POOL"
    FORECAST_MOVES = "FORECAST_MOVES"

class QueueJobState(str, Enum):
    STARTING = "STARTING"
    PROCESSING = "PROCESSING"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"

class InputTaskMessage(BaseModel):
    job_id: UUID
    command: TaskCommandType
    profile_key: str
    risk_dial_r: float = Field(ge=0.0, le=1.0)
    replication_factor: int = Field(ge=1, default=3)
    candidate_symbols: List[str]
    submitted_at_utc: datetime

class OutputStatusMessage(BaseModel):
    job_id: UUID
    status: QueueJobState
    progress_pct: float = Field(ge=0.0, le=100.0)
    confidence_score: float = Field(ge=0.0, le=1.0)
    result_payload: Optional[str] = None
    error_message: Optional[str] = None
    updated_at_utc: datetime
