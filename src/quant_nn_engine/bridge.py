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
from evolution.empirical_gradient import compute_replica_fitness, evolve_base_strategy_from_histories
from evolution.jitter_pool import build_antithetic_jitter_pool
from models.loss import DifferentiableNavSharpeLoss
from models.network import PortfolioConditionedQuantNet


class QuantBrainBridge:
    """
    High-level facade connecting `quant_nn_worker` task loop to `quant_nn_engine`.
    Performs online gradient updates on completed K-replica episodes during RECALCULATE_POOL.
    """
    def __init__(self, confidence_threshold: float = 0.75, hidden_dim: int = 64):
        self.confidence_threshold = confidence_threshold
        self.model = PortfolioConditionedQuantNet(hidden_dim=hidden_dim)
        self.optimizer = torch.optim.AdamW(self.model.parameters(), lr=4e-3, weight_decay=1e-4)
        self.loss_fn = DifferentiableNavSharpeLoss()
        self.generation_count: int = 0
        self.generation_by_profile: Dict[str, int] = {}

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

    def train_on_generation_histories(
        self,
        histories: List[ReplicaHistoryRecord],
        risk_dial_r: float,
        profile_key: str = "DEFAULT",
        epochs: int = 6,
    ) -> float:
        """
        Runs online PyTorch gradient updates over the completed K-replica batch so the network's
        strategy head, action head, and confidence gate actively learn from live agent outcomes.
        """
        if not histories:
            return 0.0

        self.model.train()
        self.generation_count += 1
        gen_num = self.generation_by_profile.get(profile_key, 0) + 1
        self.generation_by_profile[profile_key] = gen_num
        batch_size = len(histories)

        # Build informative state tensors encoding each replica's empirical metrics
        m_batch = np.zeros((batch_size, 32, 10), dtype=np.float32)
        p_batch = np.zeros((batch_size, 6), dtype=np.float32)
        returns_list = []
        conf_targets = []

        scored = [compute_replica_fitness(h) for h in histories]
        best_fit = max(scored)

        for i, h in enumerate(histories):
            norm_pnl = float(np.tanh(h.realized_pnl_usdt / 25.0))
            sharpe_clipped = float(np.clip(h.sharpe_estimate / 3.0, -1.0, 1.0))
            m_batch[i, :, 0] = norm_pnl
            m_batch[i, :, 1] = sharpe_clipped
            m_batch[i, :, 2] = float(h.max_drawdown_pct)

            p_batch[i] = [
                0.5,
                0.5,
                float(h.max_drawdown_pct),
                float(np.clip(0.5 + norm_pnl * 0.3, 0.0, 1.0)),
                1.0,
                risk_dial_r,
            ]
            # Effective directional return signal from replica fitness
            eff_ret = norm_pnl if abs(norm_pnl) > 1e-4 else (0.015 if h.sharpe_estimate >= 0 else -0.015)
            returns_list.append(eff_ret)

            # Progressive confidence curriculum as generations accumulate + positive Sharpe
            maturity_bonus = min(0.28, gen_num * 0.055)
            sharpe_bonus = max(0.0, min(0.15, h.sharpe_estimate * 0.06))
            conf_targets.append(min(0.92, 0.52 + maturity_bonus + sharpe_bonus))

        m_tensor = torch.tensor(m_batch, dtype=torch.float32)
        p_tensor = torch.tensor(p_batch, dtype=torch.float32)
        r_tensor = torch.full((batch_size, 1), risk_dial_r, dtype=torch.float32)
        fut_tensor = torch.tensor(returns_list, dtype=torch.float32)
        conf_target_tensor = torch.tensor(conf_targets, dtype=torch.float32)

        last_loss = 0.0
        for _ in range(epochs):
            self.optimizer.zero_grad()
            out = self.model(m_tensor, p_tensor, r_tensor)
            loss = self.loss_fn(out, fut_tensor, target_confidence=conf_target_tensor)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(self.model.parameters(), 1.0)
            self.optimizer.step()
            last_loss = float(loss.item())

        return last_loss

    def calculate_pool_and_forecast(
        self,
        profile_key: str,
        risk_dial_r: float,
        candidate_symbols: List[str],
        replication_factor: int,
        ohlcv_by_symbol: Optional[Dict[str, np.ndarray]] = None,
        prior_histories: Optional[List[ReplicaHistoryRecord]] = None,
    ) -> Tuple[float, Dict]:
        # 1. If prior generation histories exist, run online PyTorch training first!
        train_loss = 0.0
        if prior_histories:
            train_loss = self.train_on_generation_histories(prior_histories, risk_dial_r, profile_key=profile_key)

        # 2. Switch to eval mode to synthesize updated strategy parameters & confidence
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
            is_promoted_for_live=(
                confidence >= self.confidence_threshold
                and (
                    not prior_histories
                    or (
                        (sum(h.sharpe_estimate for h in prior_histories) / len(prior_histories)) >= 0.0
                        and max(h.sharpe_estimate for h in prior_histories) > 0.20
                    )
                )
            ),
            strategy_params=StrategyHyperparams(**avg_base),
            ranked_symbols=ranked_symbols,
            asset_forecasts=asset_forecasts,
        )

        return confidence, {
            "profile_key": profile_key,
            "generation": self.generation_by_profile.get(profile_key, self.generation_count),
            "train_loss": round(train_loss, 4),
            "winning_prior_replica": winner_replica,
            "is_promoted_for_live": forecast_pkg.is_promoted_for_live,
            "replicas": replicas,
            "forecast": forecast_pkg.model_dump(),
        }
