import sys
from pathlib import Path

worker_root = Path(__file__).resolve().parents[2] / "src" / "quant_nn_worker"
if str(worker_root) not in sys.path:
    sys.path.insert(0, str(worker_root))
