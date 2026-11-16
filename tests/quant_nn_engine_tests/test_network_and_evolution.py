import numpy as np
import torch
from bridge import QuantBrainBridge
from contracts import ReplicaHistoryRecord
from serialization.state_codec import BrainStateCodec


def test_training_step_and_bytea_state_codec_roundtrip():
    bridge = QuantBrainBridge(confidence_threshold=0.70, hidden_dim=32)
    rng = np.random.default_rng(11)
    ohlcv = np.abs(rng.normal(100, 5, size=(32, 5)))
    ohlcv[:, 1] = ohlcv[:, 0] + 2.0
    ohlcv[:, 2] = np.maximum(ohlcv[:, 0] - 2.0, 1.0)
    portfolio_vec = np.array([0.4, 0.6, 0.05, 0.60, 2.0, 0.75], dtype=np.float32)

    loss_val, conf_val = bridge.train_step_on_candles(ohlcv, portfolio_vec, risk_dial_r=0.75, future_return=0.018)
    assert np.isfinite(loss_val)
    assert 0.0 <= conf_val <= 1.0

    scaler_meta = {"BTCUSDT": {"mean": 68000.0, "std": 1450.0}}
    raw_bytes = BrainStateCodec.dump_state_bundle(bridge.model, bridge.optimizer, scaler_meta, conf_val)
    assert isinstance(raw_bytes, bytes) and len(raw_bytes) > 500

    restored_model, _, restored_scaler, restored_conf = BrainStateCodec.load_state_bundle(raw_bytes)
    assert restored_scaler == scaler_meta
    assert abs(restored_conf - conf_val) < 1e-6
    for p1, p2 in zip(bridge.model.parameters(), restored_model.parameters()):
        assert torch.allclose(p1, p2)


def test_empirical_evolution_from_k_replica_histories():
    bridge = QuantBrainBridge(confidence_threshold=0.40, hidden_dim=32)
    histories = [
        ReplicaHistoryRecord(
            replica_index=1,
            jitter_delta={"entry_threshold": 0.0, "stop_loss_atr": 0.0, "take_profit_rr": 0.0, "max_slice_claim_pct": 0.0},
            realized_pnl_usdt=12.0,
            max_drawdown_pct=0.04,
            sharpe_estimate=1.1,
        ),
        ReplicaHistoryRecord(
            replica_index=2,
            jitter_delta={"entry_threshold": 0.04, "stop_loss_atr": -0.02, "take_profit_rr": 0.05, "max_slice_claim_pct": 0.02},
            realized_pnl_usdt=48.5,
            max_drawdown_pct=0.02,
            sharpe_estimate=2.4,
        ),
        ReplicaHistoryRecord(
            replica_index=3,
            jitter_delta={"entry_threshold": -0.04, "stop_loss_atr": 0.02, "take_profit_rr": -0.05, "max_slice_claim_pct": -0.02},
            realized_pnl_usdt=-9.0,
            max_drawdown_pct=0.09,
            sharpe_estimate=-0.3,
        ),
    ]

    conf, payload = bridge.calculate_pool_and_forecast(
        profile_key="AGGRESSIVE_BREAKOUT",
        risk_dial_r=0.85,
        candidate_symbols=["SOLUSDT", "BTCUSDT", "ETHUSDT"],
        replication_factor=3,
        prior_histories=histories,
    )

    assert payload["winning_prior_replica"] == 2
    assert len(payload["replicas"]) == 3
    assert payload["replicas"][0]["replica_index"] == 1
    assert set(payload["forecast"]["ranked_symbols"]) == {"SOLUSDT", "BTCUSDT", "ETHUSDT"}
