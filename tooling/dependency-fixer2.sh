python3 - << 'EOF'
from pathlib import Path

# 1. Update conftest.py to support both host paths (src/) and container paths (/worker)
conftest = Path("tests/quant_nn_engine_tests/conftest.py")
conftest.write_text("""import sys
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
""", encoding="utf-8")
print("[OK] Updated tests/quant_nn_engine_tests/conftest.py for dual-path resolution")

# 2. Update src/quant_nn_worker/Dockerfile PYTHONPATH to include both /worker and /worker/quant_nn_engine
dockerfile = Path("src/quant_nn_worker/Dockerfile")
df_text = dockerfile.read_text(encoding="utf-8")
df_text = df_text.replace('ENV PYTHONPATH="/worker"', 'ENV PYTHONPATH="/worker:/worker/quant_nn_engine"')
dockerfile.write_text(df_text, encoding="utf-8")
print("[OK] Updated src/quant_nn_worker/Dockerfile PYTHONPATH")

# 3. Update verify-local.sh PYTHONPATH for the pytest container run
verify_sh = Path("verify-local.sh")
v_text = verify_sh.read_text(encoding="utf-8")
v_text = v_text.replace('-e PYTHONPATH="/worker"', '-e PYTHONPATH="/worker:/worker/quant_nn_engine"')
verify_sh.write_text(v_text, encoding="utf-8")
print("[OK] Updated verify-local.sh PYTHONPATH")
EOF