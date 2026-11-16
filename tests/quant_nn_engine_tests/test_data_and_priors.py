import hashlib
import io
import zipfile
import numpy as np
import pytest
from data.binance_vision import build_daily_kline_url, parse_kline_zip_bytes
from data.indicators import FEATURE_NAMES, compute_canonical_pattern_priors
from data.synthetic_portfolio import generate_arbitrary_portfolios


def test_binance_vision_zip_stream_and_checksum():
    url = build_daily_kline_url("solusdt", "15m", "2026-10-01")
    assert url.endswith("/SOLUSDT/15m/SOLUSDT-15m-2026-10-01.zip")

    csv_content = (
        "1700000000000,150.0,155.0,149.0,154.0,1200.5,1700000899999,180000.0,100,600.0,90000.0,0\n"
        "1700000900000,154.0,158.0,153.5,157.2,1850.0,1700001799999,290000.0,140,950.0,149000.0,0\n"
    ).encode("utf-8")

    zbuf = io.BytesIO()
    with zipfile.ZipFile(zbuf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("SOLUSDT-15m-2026-10-01.csv", csv_content)
    raw_zip = zbuf.getvalue()
    sha = hashlib.sha256(raw_zip).hexdigest()

    candles = list(parse_kline_zip_bytes(raw_zip, expected_sha256=sha))
    assert len(candles) == 2
    assert candles[0].close == 154.0
    assert candles[1].high == 158.0

    with pytest.raises(ValueError, match="SHA-256 mismatch"):
        list(parse_kline_zip_bytes(raw_zip, expected_sha256="0000deadbeef"))


def test_canonical_pattern_priors_bounds_and_shape():
    rng = np.random.default_rng(7)
    prices = 100.0 + np.cumsum(rng.normal(0, 1.2, size=64))
    ohlcv = np.column_stack([
        prices,
        prices + rng.uniform(0.2, 1.5, size=64),
        prices - rng.uniform(0.2, 1.5, size=64),
        prices + rng.normal(0, 0.4, size=64),
        rng.uniform(100, 5000, size=64),
    ])
    priors = compute_canonical_pattern_priors(ohlcv)
    assert priors.shape == (64, len(FEATURE_NAMES))
    assert np.all(priors >= -1.0) and np.all(priors <= 1.0)


def test_arbitrary_portfolio_generator():
    portfolios = list(generate_arbitrary_portfolios(["BTCUSDT", "SOLUSDT", "ETHUSDT"], batch_size=5))
    assert len(portfolios) == 5
    for p in portfolios:
        total = p.usdt_cash_ratio + sum(p.asset_weights.values())
        assert abs(total - 1.0) < 1e-2
