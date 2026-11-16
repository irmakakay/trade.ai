from typing import Dict, List, Tuple
from contracts import ReplicaHistoryRecord


def compute_replica_fitness(rec: ReplicaHistoryRecord, drawdown_lambda: float = 50.0) -> float:
    return float(
        rec.realized_pnl_usdt
        + (rec.sharpe_estimate * 10.0)
        - (rec.max_drawdown_pct * drawdown_lambda)
        - rec.fee_drag_usdt
    )


def evolve_base_strategy_from_histories(
    current_base: Dict[str, float],
    histories: List[ReplicaHistoryRecord],
    step_size: float = 0.50,
) -> Tuple[Dict[str, float], int]:
    """
    Reads all K replica histories from the previous run, identifies the top-performing
    replica, and shifts the base strategy vector toward the winning jitter direction.
    Returns (updated_base_strategy, winning_replica_index).
    """
    if not histories:
        return dict(current_base), 1

    scored = [(compute_replica_fitness(h), h) for h in histories]
    scored.sort(key=lambda pair: pair[0], reverse=True)
    best_fitness, winner = scored[0]

    updated = {}
    for key, base_val in current_base.items():
        win_delta = winner.jitter_delta.get(key, 0.0)
        # Shift base parameter toward winning perturbation
        shifted = base_val * (1.0 + step_size * win_delta)
        updated[key] = round(max(0.01, float(shifted)), 4)

    return updated, winner.replica_index
