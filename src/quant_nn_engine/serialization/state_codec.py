import io
from typing import Any, Dict, Tuple
import torch
from models.network import PortfolioConditionedQuantNet


class BrainStateCodec:
    @staticmethod
    def dump_state_bundle(
        model: PortfolioConditionedQuantNet,
        optimizer: torch.optim.Optimizer,
        scaler_stats: Dict[str, Any],
        confidence_score: float,
    ) -> bytes:
        buf = io.BytesIO()
        bundle = {
            "arch": {
                "market_feature_dim": model.market_feature_dim,
                "portfolio_feature_dim": model.portfolio_feature_dim,
                "hidden_dim": model.hidden_dim,
            },
            "model_state": model.state_dict(),
            "optimizer_state": optimizer.state_dict(),
            "scaler_stats": scaler_stats,
            "confidence_score": float(confidence_score),
        }
        torch.save(bundle, buf)
        return buf.getvalue()

    @staticmethod
    def load_state_bundle(
        raw_bytes: bytes,
        lr: float = 1e-3,
    ) -> Tuple[PortfolioConditionedQuantNet, torch.optim.Optimizer, Dict[str, Any], float]:
        buf = io.BytesIO(raw_bytes)
        bundle = torch.load(buf, weights_only=False)
        arch = bundle["arch"]
        model = PortfolioConditionedQuantNet(
            market_feature_dim=arch["market_feature_dim"],
            portfolio_feature_dim=arch["portfolio_feature_dim"],
            hidden_dim=arch["hidden_dim"],
        )
        model.load_state_dict(bundle["model_state"])
        optimizer = torch.optim.AdamW(model.parameters(), lr=lr)
        optimizer.load_state_dict(bundle["optimizer_state"])
        return model, optimizer, bundle["scaler_stats"], float(bundle["confidence_score"])
