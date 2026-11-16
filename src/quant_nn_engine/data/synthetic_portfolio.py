from typing import Iterator, List
import numpy as np
from contracts import PortfolioSnapshot


def generate_arbitrary_portfolios(
    symbols: List[str],
    batch_size: int,
    seed: int = 42,
) -> Iterator[PortfolioSnapshot]:
    """
    Lazy generator producing diverse synthetic portfolio states (cash-heavy, concentrated,
    in drawdown, or on winning streaks) so the NN generalizes across any live portfolio state.
    """
    rng = np.random.default_rng(seed)
    n_sym = max(len(symbols), 1)

    for _ in range(batch_size):
        raw_alloc = rng.dirichlet(np.ones(n_sym + 1))
        cash_ratio = float(np.round(raw_alloc[0], 4))
        asset_weights = {
            symbols[i]: float(np.round(raw_alloc[i + 1], 4))
            for i in range(len(symbols))
        }
        drawdown = float(np.round(rng.beta(1.5, 8.0), 4))
        win_rate = float(np.round(rng.uniform(0.25, 0.80), 4))
        streak = int(rng.integers(-5, 6))

        yield PortfolioSnapshot(
            usdt_cash_ratio=cash_ratio,
            asset_weights=asset_weights,
            current_drawdown_pct=drawdown,
            recent_win_rate=win_rate,
            active_streak=streak,
        )
