import sys
from pathlib import Path

repo_root = Path(__file__).resolve().parents[2]
candidates = [
    repo_root / "src",
    repo_root / "src" / "quant_nn_engine",
    Path("/worker"),
    Path("/worker/quant_nn_engine"),
]
for p in candidates:
    if p.exists() and str(p) not in sys.path:
        sys.path.insert(0, str(p))
