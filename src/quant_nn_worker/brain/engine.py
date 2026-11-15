from typing import Dict, List
import numpy as np
import torch
import torch.nn as nn

class StrategyConditionedNet(nn.Module):
    def __init__(self, feature_dim: int = 16, hidden_dim: int = 32):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(feature_dim + 1, hidden_dim),
            nn.GELU(),
            nn.Linear(hidden_dim, 4),
            nn.Sigmoid(),
        )

    def forward(self, market_features: torch.Tensor, risk_dial_r: float) -> Dict[str, float]:
        r_tensor = torch.tensor([[risk_dial_r]], dtype=torch.float32)
        x = torch.cat([market_features, r_tensor], dim=-1)
        with torch.no_grad():
            out = self.net(x).squeeze(0).tolist()
        return {
            "entry_threshold": round(0.50 + (1.0 - risk_dial_r) * 0.35 + out[0] * 0.1, 4),
            "stop_loss_atr": round(1.0 + risk_dial_r * 1.5 + out[1] * 0.2, 4),
            "take_profit_rr": round(1.2 + risk_dial_r * 2.5 + out[2] * 0.3, 4),
            "max_slice_claim_pct": round(0.15 + risk_dial_r * 0.35, 4),
        }

def generate_epsilon_jittered_pool(
    base_strategy: Dict[str, float],
    candidate_symbols: List[str],
    replication_factor: int,
    epsilon_scale: float = 0.025,
    seed: int = 42,
) -> List[Dict]:
    rng = np.random.default_rng(seed)
    replicas = []
    keys = sorted(base_strategy.keys())

    for idx in range(1, replication_factor + 1):
        if idx == 1:
            # Replica #1 is always the exact Anchor (0 jitter)
            delta = {k: 0.0 for k in keys}
            payload = dict(base_strategy)
            ordered_symbols = list(candidate_symbols)
        else:
            # Antithetic mirrored sampling (+/- epsilon)
            sign = 1.0 if idx % 2 == 0 else -1.0
            pair_seed = idx // 2
            pair_rng = np.random.default_rng(seed + pair_seed)
            raw_noise = pair_rng.uniform(0.01, epsilon_scale, size=len(keys))
            delta = {k: round(float(sign * raw_noise[i]), 4) for i, k in enumerate(keys)}
            payload = {k: round(max(0.01, base_strategy[k] * (1.0 + delta[k])), 4) for k in keys}
            ordered_symbols = list(candidate_symbols)
            if len(ordered_symbols) > 1 and idx % 2 == 1:
                ordered_symbols = ordered_symbols[1:] + ordered_symbols[:1]

        replicas.append({
            "replica_index": idx,
            "jitter_delta": delta,
            "strategy_payload": payload,
            "candidate_symbols": ordered_symbols,
        })
    return replicas
