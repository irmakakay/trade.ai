import torch
from brain.engine import StrategyConditionedNet, generate_epsilon_jittered_pool

def test_strategy_conditioned_net_respects_risk_spectrum():
    net = StrategyConditionedNet(feature_dim=16, hidden_dim=32)
    x = torch.zeros((1, 16), dtype=torch.float32)
    careful = net(x, risk_dial_r=0.1)
    aggressive = net(x, risk_dial_r=0.9)

    assert careful["entry_threshold"] > aggressive["entry_threshold"]
    assert aggressive["take_profit_rr"] > careful["take_profit_rr"]
    assert aggressive["max_slice_claim_pct"] > careful["max_slice_claim_pct"]

def test_epsilon_jitter_pool_anchor_and_antithetic_mirrors():
    base = {"entry_threshold": 0.65, "stop_loss_atr": 1.5, "take_profit_rr": 2.0, "max_slice_claim_pct": 0.25}
    pool = generate_epsilon_jittered_pool(base, ["SOLUSDT", "BTCUSDT"], replication_factor=3, epsilon_scale=0.03)

    assert len(pool) == 3
    # Replica 1 is exact anchor
    assert pool[0]["replica_index"] == 1
    assert all(v == 0.0 for v in pool[0]["jitter_delta"].values())
    assert pool[0]["strategy_payload"] == base

    # Replica 2 and 3 have mirrored opposite signs
    for key in base:
        assert pool[1]["jitter_delta"][key] == -pool[2]["jitter_delta"][key]
        assert pool[1]["jitter_delta"][key] != 0.0
