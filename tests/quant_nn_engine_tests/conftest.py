import sys
from pathlib import Path

engine_root = Path(__file__).resolve().parents[2] / "src" / "quant_nn_engine"
if str(engine_root) not in sys.path:
    sys.path.insert(0, str(engine_root))
