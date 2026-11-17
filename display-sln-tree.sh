python3 - << 'EOF'
import os
from pathlib import Path

IGNORE = {
    ".git", "node_modules", "bin", "obj", "__pycache__",
    ".pytest_cache", ".venv", "venv", "dist", ".vs", ".vscode"
}

print("=== 1. DIRECTORY & FILE TREE ===")
for root, dirs, files in os.walk("."):
    dirs[:] = sorted([d for d in dirs if d not in IGNORE and not d.endswith(".egg-info")])
    level = root.replace(".", "", 1).count(os.sep)
    indent = "  " * level
    folder_name = os.path.basename(root) or "quant-core (.)"
    print(f"{indent}📁 {folder_name}/")
    subindent = "  " * (level + 1)
    for f in sorted(files):
        if f.endswith((".pyc", ".DS_Store")):
            continue
        print(f"{subindent}📄 {f}")

print("\n=== 2. QuantCore.sln PROJECTS ===")
sln = Path("QuantCore.sln")
print(sln.read_text() if sln.exists() else "MISSING: QuantCore.sln")

print("\n=== 3. src/quant_nn_worker/Dockerfile ===")
df = Path("src/quant_nn_worker/Dockerfile")
print(df.read_text() if df.exists() else "MISSING: src/quant_nn_worker/Dockerfile")
EOF