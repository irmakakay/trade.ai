import numpy as np

FEATURE_NAMES = (
    "log_return",
    "ema_9_21_spread",
    "ema_21_50_spread",
    "rsi_14_norm",
    "atr_14_pct",
    "bollinger_pct_b",
    "vwap_zscore",
    "volume_zscore",
    "range_position",
    "volatility_squeeze",
)


def _ema(arr: np.ndarray, span: int) -> np.ndarray:
    alpha = 2.0 / (span + 1.0)
    out = np.empty_like(arr, dtype=np.float64)
    out[0] = arr[0]
    for i in range(1, len(arr)):
        out[i] = alpha * arr[i] + (1.0 - alpha) * out[i - 1]
    return out


def compute_canonical_pattern_priors(ohlcv: np.ndarray) -> np.ndarray:
    """
    ohlcv: shape (T, 5) -> [open, high, low, close, volume]
    Returns normalized feature matrix of shape (T, 10) clipped to [-1.0, 1.0].
    """
    if ohlcv.ndim != 2 or ohlcv.shape[1] < 5:
        raise ValueError("Expected ohlcv array of shape (T, 5)")

    high = ohlcv[:, 1].astype(np.float64)
    low = ohlcv[:, 2].astype(np.float64)
    close = np.maximum(ohlcv[:, 3].astype(np.float64), 1e-8)
    volume = np.maximum(ohlcv[:, 4].astype(np.float64), 0.0)
    t_len = len(close)

    # 1. Log return
    log_ret = np.zeros(t_len, dtype=np.float64)
    log_ret[1:] = np.log(close[1:] / close[:-1])
    f_log_ret = np.tanh(log_ret * 50.0)

    # 2 & 3. EMA trend alignment spreads
    ema9 = _ema(close, 9)
    ema21 = _ema(close, 21)
    ema50 = _ema(close, 50)
    f_ema_9_21 = np.tanh(((ema9 - ema21) / close) * 40.0)
    f_ema_21_50 = np.tanh(((ema21 - ema50) / close) * 30.0)

    # 4. RSI-14 normalized to [-1, 1]
    delta = np.diff(close, prepend=close[0])
    gains = np.where(delta > 0, delta, 0.0)
    losses = np.where(delta < 0, -delta, 0.0)
    avg_gain = _ema(gains, 14) + 1e-8
    avg_loss = _ema(losses, 14) + 1e-8
    rs = avg_gain / avg_loss
    rsi = 100.0 - (100.0 / (1.0 + rs))
    f_rsi = (rsi - 50.0) / 50.0

    # 5. ATR-14 normalized percentage
    prev_close = np.roll(close, 1)
    prev_close[0] = close[0]
    tr = np.maximum(high - low, np.maximum(np.abs(high - prev_close), np.abs(low - prev_close)))
    atr14 = _ema(tr, 14)
    f_atr = np.tanh((atr14 / close) * 25.0)

    # 6. Bollinger %B (20-period) centered around 0
    ema20 = _ema(close, 20)
    var20 = _ema((close - ema20) ** 2, 20)
    std20 = np.sqrt(np.maximum(var20, 1e-10))
    f_bb = np.tanh((close - ema20) / (2.0 * std20))

    # 7. Rolling VWAP deviation
    typ_price = (high + low + close) / 3.0
    cum_pv = _ema(typ_price * (volume + 1.0), 20)
    cum_v = _ema(volume + 1.0, 20)
    vwap = cum_pv / np.maximum(cum_v, 1e-8)
    f_vwap = np.tanh(((close - vwap) / close) * 40.0)

    # 8. Volume climax z-score
    vol_ema = _ema(volume, 20)
    vol_std = np.sqrt(_ema((volume - vol_ema) ** 2, 20) + 1e-8)
    f_vol_z = np.tanh((volume - vol_ema) / vol_std)

    # 9. Candle structure range position
    hl_span = np.maximum(high - low, 1e-8)
    f_range_pos = ((close - low) / hl_span) * 2.0 - 1.0

    # 10. Volatility squeeze (ratio of short ATR to long ATR)
    atr50 = _ema(tr, 50) + 1e-8
    f_squeeze = np.tanh((atr14 / atr50) - 1.0)

    features = np.column_stack([
        f_log_ret,
        f_ema_9_21,
        f_ema_21_50,
        f_rsi,
        f_atr,
        f_bb,
        f_vwap,
        f_vol_z,
        f_range_pos,
        f_squeeze,
    ])
    return np.clip(features.astype(np.float32), -1.0, 1.0)
