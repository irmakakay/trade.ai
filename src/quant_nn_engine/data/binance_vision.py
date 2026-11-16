import csv
import hashlib
import io
import urllib.request
import zipfile
from typing import Iterator, Optional
from contracts import MarketCandle

BINANCE_VISION_BASE = "https://data.binance.vision/data/spot/daily/klines"


def build_daily_kline_url(symbol: str, interval: str, date_yyyy_mm_dd: str) -> str:
    sym = symbol.upper()
    return f"{BINANCE_VISION_BASE}/{sym}/{interval}/{sym}-{interval}-{date_yyyy_mm_dd}.zip"


def parse_kline_zip_bytes(zip_bytes: bytes, expected_sha256: Optional[str] = None) -> Iterator[MarketCandle]:
    if expected_sha256 is not None:
        digest = hashlib.sha256(zip_bytes).hexdigest()
        if digest.lower() != expected_sha256.strip().split()[0].lower():
            raise ValueError(f"SHA-256 mismatch: expected {expected_sha256}, got {digest}")

    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        for name in zf.namelist():
            if not name.endswith(".csv"):
                continue
            with zf.open(name) as csv_file:
                text_stream = io.TextIOWrapper(csv_file, encoding="utf-8")
                reader = csv.reader(text_stream)
                for row in reader:
                    if not row or not row[0].isdigit():
                        continue
                    yield MarketCandle(
                        timestamp_ms=int(row[0]),
                        open=float(row[1]),
                        high=float(row[2]),
                        low=float(row[3]),
                        close=float(row[4]),
                        volume=float(row[5]),
                    )


def stream_daily_klines(symbol: str, interval: str, date_yyyy_mm_dd: str, timeout: int = 15) -> Iterator[MarketCandle]:
    url = build_daily_kline_url(symbol, interval, date_yyyy_mm_dd)
    req = urllib.request.Request(url, headers={"User-Agent": "QuantCore-ZeroCost-Loader/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        zip_bytes = resp.read()
    yield from parse_kline_zip_bytes(zip_bytes)
