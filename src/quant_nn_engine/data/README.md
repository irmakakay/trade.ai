# Data & Priors Submodule (`quant_nn_engine.data`)
- `binance_vision.py`: Streams public `data.binance.vision` kline ZIP archives in memory using standard `urllib` + `zipfile` + `hashlib` ($0 cost, zero API keys).
- `indicators.py`: Computes 10 canonical trading knowledge features per candle (log returns, EMA 9/21/50 trend spreads, RSI-14, ATR-14 volatility ratio, Bollinger %B, volume climax z-score, VWAP deviation, and structure high/low position).
- `synthetic_portfolio.py`: Lazy generator yielding randomized portfolio holdings and drawdown states so the NN learns optimal actions across arbitrary portfolio conditions.
