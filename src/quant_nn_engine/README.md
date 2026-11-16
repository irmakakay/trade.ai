# quant_nn_engine (Isolated Multi-Head Time-Series & Portfolio PyTorch Engine)
- `contracts.py`: Pydantic v2 schemas for candle windows, portfolio states, strategy vectors, and move forecasts.
- `data/`: Zero-cost `data.binance.vision` OHLCV ZIP downloader (SHA-256 verified), vectorized indicator priors normalized to $[-1, 1]$, and synthetic portfolio generator.
- `models/`: 3-stream PyTorch network (causal Conv1D + GRU, portfolio encoder, FiLM risk dial $r \in [0, 1]$) with 3 heads, plus differentiable Sharpe/drawdown/fee-aware NAV loss.
- `evolution/`: Antithetic $\pm\epsilon$ $K$-replica jitter pool and empirical-gradient update from completed `TradingHistory` outcomes.
- `serialization/`: Lossless in-memory `bytes` (`BYTEA`) codec for weights, optimizer state, scalers, and confidence.
- `bridge.py`: Facade mapping `quant_nn_worker/adapter/schemas.py` `InputTaskMessage` to `(confidence, result_dict)`.

Torch/NumPy/Pydantic only: zero DB (`psycopg`) or AMQP (`pika`) imports.
