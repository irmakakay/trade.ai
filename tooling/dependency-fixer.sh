python3 - << 'EOF'
from pathlib import Path

# 1. Add __init__.py to flattened src/quant_nn_engine so Python recognizes it as a package
init_file = Path("src/quant_nn_engine/__init__.py")
init_file.write_text("""from quant_nn_engine.contracts import (
    AssetMoveForecast,
    ForecastPackage,
    MarketCandle,
    PortfolioSnapshot,
    ReplicaHistoryRecord,
    StrategyHyperparams,
)
from quant_nn_engine.models.network import PortfolioConditionedQuantNet
from quant_nn_engine.serialization.state_codec import BrainStateCodec
from quant_nn_engine.bridge import QuantBrainBridge

__all__ = [
    "AssetMoveForecast",
    "ForecastPackage",
    "MarketCandle",
    "PortfolioSnapshot",
    "ReplicaHistoryRecord",
    "StrategyHyperparams",
    "PortfolioConditionedQuantNet",
    "BrainStateCodec",
    "QuantBrainBridge",
]
""", encoding="utf-8")
print("[OK] Created src/quant_nn_engine/__init__.py")

# 2. Update src/quant_nn_worker/Dockerfile to copy flattened package directly into /worker/quant_nn_engine
dockerfile = Path("src/quant_nn_worker/Dockerfile")
dockerfile.write_text("""FROM python:3.11-slim
WORKDIR /worker

# Install worker & engine dependencies
COPY src/quant_nn_worker/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy flattened quant_nn_engine package directly into /worker/quant_nn_engine
COPY src/quant_nn_engine ./quant_nn_engine

# Copy worker adapter & entrypoint
COPY src/quant_nn_worker/ ./
ENV PYTHONPATH="/worker"
CMD ["python", "main.py"]
""", encoding="utf-8")
print("[OK] Updated src/quant_nn_worker/Dockerfile")

# 3. Fix tests/quant_nn_engine_tests/conftest.py so `import quant_nn_engine` resolves from `src/`
conftest = Path("tests/quant_nn_engine_tests/conftest.py")
conftest.write_text("""import sys
from pathlib import Path

src_root = Path(__file__).resolve().parents[2] / "src"
if str(src_root) not in sys.path:
    sys.path.insert(0, str(src_root))
""", encoding="utf-8")
print("[OK] Updated tests/quant_nn_engine_tests/conftest.py")

# 4. Update verify-local.sh Step 5 volume mount so /worker/quant_nn_engine is used directly
verify_sh = Path("verify-local.sh")
if verify_sh.exists():
    text = verify_sh.read_text(encoding="utf-8")
    text = text.replace(
        '-v "$(pwd)/src/quant_nn_engine:/engine" \\\n    -e PYTHONPATH="/worker:/engine"',
        '-e PYTHONPATH="/worker"'
    )
    verify_sh.write_text(text, encoding="utf-8")
    print("[OK] Updated verify-local.sh PYTHONPATH mount")
EOF