import psycopg


def fetch_execution_reward_adjustment(conn_str: str, lookback_minutes: int = 60) -> dict:
    """
    Computes execution quality adjustments from recent Revolut X (LIVE / DRY_RUN)
    and simulated orders so the 128-dim NN penalizes high slippage and rejected orders.
    """
    stats = {
        "total_orders": 0,
        "rejected_orders": 0,
        "avg_slippage_bps": 0.0,
        "reward_penalty": 0.0,
    }
    if not conn_str:
        return stats

    dsn = (
        conn_str.replace("postgresql+psycopg2://", "postgresql://")
        .replace("postgresql+psycopg://", "postgresql://")
    )

    try:
        with psycopg.connect(dsn) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT
                        COUNT(*) AS total_orders,
                        COUNT(*) FILTER (WHERE NOT accepted) AS rejected_orders,
                        COALESCE(AVG(slippage_bps) FILTER (WHERE accepted), 0.0) AS avg_slippage_bps
                    FROM execution_history
                    WHERE created_at >= NOW() - (%s || ' minutes')::INTERVAL
                      AND provider = 'REVOLUT_X';
                    """,
                    (str(lookback_minutes),),
                )
                row = cur.fetchone()
                if row and row[0] > 0:
                    total_orders = int(row[0])
                    rejected_orders = int(row[1])
                    avg_slippage_bps = float(row[2])

                    rejection_rate = rejected_orders / max(total_orders, 1)
                    slippage_penalty = max(0.0, (avg_slippage_bps - 5.0) * 0.01)
                    rejection_penalty = rejection_rate * 0.50

                    stats.update({
                        "total_orders": total_orders,
                        "rejected_orders": rejected_orders,
                        "avg_slippage_bps": round(avg_slippage_bps, 4),
                        "reward_penalty": round(slippage_penalty + rejection_penalty, 6),
                    })
    except Exception as exc:
        print(f"[execution_feedback] Non-fatal query warning: {exc}", flush=True)

    return stats
