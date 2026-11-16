from enum import Enum
from typing import Dict, List
from pydantic import BaseModel, Field


class TradeActionType(str, Enum):
    BUY = "BUY"
    SELL = "SELL"
    HOLD = "HOLD"


class MarketCandle(BaseModel):
    timestamp_ms: int
    open: float
    high: float
    low: float
    close: float
    volume: float


class PortfolioSnapshot(BaseModel):
    usdt_cash_ratio: float = Field(ge=0.0, le=1.0)
    asset_weights: Dict[str, float]
    current_drawdown_pct: float = Field(ge=0.0, le=1.0)
    recent_win_rate: float = Field(ge=0.0, le=1.0, default=0.5)
    active_streak: int = 0


class StrategyHyperparams(BaseModel):
    entry_threshold: float = Field(ge=0.01, le=0.99)
    stop_loss_atr: float = Field(ge=0.1, le=10.0)
    take_profit_rr: float = Field(ge=0.5, le=20.0)
    max_slice_claim_pct: float = Field(ge=0.01, le=1.0)


class AssetMoveForecast(BaseModel):
    symbol: str
    suitability_score: float = Field(ge=0.0, le=1.0)
    recommended_action: TradeActionType
    target_slice_pct: float = Field(ge=0.0, le=1.0)
    expected_return_bps: float


class ForecastPackage(BaseModel):
    profile_key: str
    risk_dial_r: float
    confidence_score: float = Field(ge=0.0, le=1.0)
    is_promoted_for_live: bool
    strategy_params: StrategyHyperparams
    ranked_symbols: List[str]
    asset_forecasts: List[AssetMoveForecast]


class ReplicaHistoryRecord(BaseModel):
    replica_index: int = Field(ge=1)
    jitter_delta: Dict[str, float]
    realized_pnl_usdt: float
    max_drawdown_pct: float = Field(ge=0.0)
    sharpe_estimate: float
    fee_drag_usdt: float = Field(ge=0.0, default=0.0)
