from typing import Dict, List
import numpy as np


def build_antithetic_jitter_pool(
    base_strategy: Dict[str, float],
    ranked_symbols: List[str],
    replication_factor: int,
    epsilon_scale: float = 0.025,
    seed: int = 42,
) -> List[Dict]:
    if replication_factor < 1:
        raise ValueError("replication_factor must be >= 1")

    keys = sorted(base_strategy.keys())
    replicas = []

    for idx in range(1, replication_factor + 1):
        if idx == 1:
            delta = {k: 0.0 for k in keys}
            payload = {k: round(float(base_strategy[k]), 4) for k in keys}
            symbols = list(ranked_symbols)
        else:
            sign = 1.0 if idx % 2 == 0 else -1.0
            pair_id = idx // 2
            rng = np.random.default_rng(seed + pair_id)
            noise = rng.uniform(0.01, epsilon_scale, size=len(keys))
            delta = {k: round(float(sign * noise[i]), 4) for i, k in enumerate(keys)}
            payload = {
                k: round(max(0.01, float(base_strategy[k]) * (1.0 + delta[k])), 4)
                for k in keys
            }
            symbols = list(ranked_symbols)
            if len(symbols) > 1 and idx % 2 == 1:
                symbols = symbols[1:] + symbols[:1]

        replicas.append({
            "replica_index": idx,
            "jitter_delta": delta,
            "strategy_payload": payload,
            "candidate_symbols": symbols,
        })
    return replicas
