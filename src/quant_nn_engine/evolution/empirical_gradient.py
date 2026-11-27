import math
from typing import Dict, List, Tuple
from contracts import ReplicaHistoryRecord


def compute_replica_fitness(rec: ReplicaHistoryRecord, drawdown_lambda: float = 50.0) -> float:
    """
    Slice-size-neutral fitness score: compresses raw USDT PnL via tanh so inventory claim
    race order or outliers cannot override risk-adjusted Sharpe and drawdown discipline.
    """
    bounded_pnl = math.tanh(float(rec.realized_pnl_usdt) / 50.0) * 8.0
    clipped_sharpe = max(-5.0, min(5.0, float(rec.sharpe_estimate)))
    drawdown_pen = float(rec.max_drawdown_pct) * drawdown_lambda
    fee_pen = min(float(rec.fee_drag_usdt), 50.0)
    return float(bounded_pnl + (clipped_sharpe * 12.0) - drawdown_pen - fee_pen)


def evolve_base_strategy_from_histories(
    current_base: Dict[str, float],
    histories: List[ReplicaHistoryRecord],
    step_size: float = 0.50,
) -> Tuple[Dict[str, float], int]:
    """
    Reads all K replica histories from the previous run, identifies the top-performing
    replica by risk-adjusted fitness, and shifts the base strategy vector toward the
    winning jitter direction. Returns (updated_base_strategy, winning_replica_index).
    """
    if not histories:
        return dict(current_base), 1

    scored = [(compute_replica_fitness(h), h) for h in histories]
    scored.sort(key=lambda pair: pair[0], reverse=True)
    _, winner = scored[0]

    updated = {}
    for key, base_val in current_base.items():
        win_delta = winner.jitter_delta.get(key, 0.0)
        shifted = base_val * (1.0 + step_size * win_delta)
        updated[key] = round(max(0.01, float(shifted)), 4)

    return updated, winner.replica_index
