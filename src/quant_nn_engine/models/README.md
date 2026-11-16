# PyTorch Models & Loss Submodule (`quant_nn_engine.models`)
- `PortfolioConditionedQuantNet`: Combines a Causal Conv1D + GRU temporal encoder, a portfolio state encoder, and a FiLM (Feature-wise Linear Modulation) risk-dial conditioning layer ($r \in [0, 1]$).
- Emits 3 heads:
  1. `strategy_params`: (`entry_threshold`, `stop_loss_atr`, `take_profit_rr`, `max_slice_claim_pct`)
  2. `action_logits`: (`BUY`, `SELL`, `HOLD`) + `slice_fraction` + `suitability_score` per symbol
  3. `confidence_score`: Calibrated readiness metric $\in [0, 1]$ gated against `CONFIDENCE_THRESHOLD`.
