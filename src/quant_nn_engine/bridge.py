from typing import Dict, List, Optional, Tuple
import numpy as np
import torch
from contracts import (
    AssetMoveForecast,
    ForecastPackage,
    ReplicaHistoryRecord,
    StrategyHyperparams,
    TradeActionType,
)
from data.indicators import compute_canonical_pattern_priors
from evolution.empirical_gradient import evolve_base_strategy_from_histories
from evolution.jitter_pool import build_antithetic_jitter_pool
from models.loss import DifferentiableNavSharpeLoss
from models.network import PortfolioConditionedQuantNet


class QuantBrainBridge:
    """
    High-level facade connecting your existing `quant_nn_worker` task loop to `quant_nn_engine`
    without requiring any changes to `QuantCore.Contracts` or `adapter/schemas.py`.
    """
    def __init__(self, confidence_threshold: float = 0.75, hidden_dim: int = 64):
        self.confidence_threshold = confidence_threshold
        self.model = PortfolioConditionedQuantNet(hidden_dim=hidden_dim)
        self.optimizer = torch.optim.AdamW(self.model.parameters(), lr=1e-3)
        self.loss_fn = DifferentiableNavSharpeLoss()

    def train_step_on_candles(
        self,
        ohlcv_window: np.ndarray,
        portfolio_vec: np.ndarray,
        risk_dial_r: float,
        future_return: float,
    ) -> Tuple[float, float]:
        self.model.train()
        priors = compute_canonical_pattern_priors(ohlcv_window)
        m_tensor = torch.tensor(priors, dtype=torch.float32).unsqueeze(0)
        p_tensor = torch.tensor(portfolio_vec, dtype=torch.float32).unsqueeze(0)
        r_tensor = torch.tensor([[risk_dial_r]], dtype=torch.float32)
        fut_tensor = torch.tensor([future_return], dtype=torch.float32)

        self.optimizer.zero_grad()
        out = self.model(m_tensor, p_tensor, r_tensor)
        loss = self.loss_fn(out, fut_tensor)
        loss.backward()
        self.optimizer.step()

        return float(loss.item()), float(out["confidence_score"].item())

    def calculate_pool_and_forecast(
        self,
        profile_key: str,
        risk_dial_r: float,
        candidate_symbols: List[str],
        replication_factor: int,
        ohlcv_by_symbol: Optional[Dict[str, np.ndarray]] = None,
        prior_histories: Optional[List[ReplicaHistoryRecord]] = None,
    ) -> Tuple[float, Dict]:
        self.model.eval()
        p_tensor = torch.tensor([[0.5, 0.5, 0.0, 0.55, 1.0, risk_dial_r]], dtype=torch.float32)
        r_tensor = torch.tensor([[risk_dial_r]], dtype=torch.float32)

        asset_forecasts: List[AssetMoveForecast] = []
        base_params_accum = []

        for sym in candidate_symbols:
            if ohlcv_by_symbol and sym in ohlcv_by_symbol:
                priors = compute_canonical_pattern_priors(ohlcv_by_symbol[sym])
            else:
                priors = np.zeros((32, 10), dtype=np.float32)

            m_tensor = torch.tensor(priors, dtype=torch.float32).unsqueeze(0)
            with torch.no_grad():
                out = self.model(m_tensor, p_tensor, r_tensor)

            probs = torch.softmax(out["action_logits"][0], dim=-1).tolist()
            action_idx = int(np.argmax(probs))
            action = [TradeActionType.BUY, TradeActionType.SELL, TradeActionType.HOLD][action_idx]

            asset_forecasts.append(
                AssetMoveForecast(
                    symbol=sym,
                    suitability_score=round(float(out["suitability_score"][0].item()), 4),
                    recommended_action=action,
                    target_slice_pct=round(float(out["target_slice_pct"][0].item()), 4),
                    expected_return_bps=round((probs[0] - probs[1]) * 45.0, 2),
                )
            )
            base_params_accum.append({
                "entry_threshold": float(out["entry_threshold"][0].item()),
                "stop_loss_atr": float(out["stop_loss_atr"][0].item()),
                "take_profit_rr": float(out["take_profit_rr"][0].item()),
                "max_slice_claim_pct": float(out["max_slice_claim_pct"][0].item()),
                "confidence": float(out["confidence_score"][0].item()),
            })

        avg_base = {
            k: round(float(np.mean([b[k] for b in base_params_accum])), 4)
            for k in ("entry_threshold", "stop_loss_atr", "take_profit_rr", "max_slice_claim_pct")
        }
        confidence = round(float(np.mean([b["confidence"] for b in base_params_accum])), 4)

        winner_replica = 1
        if prior_histories:
            avg_base, winner_replica = evolve_base_strategy_from_histories(avg_base, prior_histories)

        # Sort symbols by suitability score descending so best-matching shares are claimed first
        asset_forecasts.sort(key=lambda f: f.suitability_score, reverse=True)
        ranked_symbols = [f.symbol for f in asset_forecasts]

        replicas = build_antithetic_jitter_pool(
            base_strategy=avg_base,
            ranked_symbols=ranked_symbols,
            replication_factor=replication_factor,
        )

        forecast_pkg = ForecastPackage(
            profile_key=profile_key,
            risk_dial_r=risk_dial_r,
            confidence_score=confidence,
            is_promoted_for_live=confidence >= self.confidence_threshold,
            strategy_params=StrategyHyperparams(**avg_base),
            ranked_symbols=ranked_symbols,
            asset_forecasts=asset_forecasts,
        )

        return confidence, {
            "profile_key": profile_key,
            "winning_prior_replica": winner_replica,
            "is_promoted_for_live": forecast_pkg.is_promoted_for_live,
            "replicas": replicas,
            "forecast": forecast_pkg.model_dump(),
        }
