#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

export REPO_ROOT

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}━━━ [$(date +%H:%M:%S)] Fixing Remaining claimed_by_agent References in Scripts ━━━${NC}"

python3 - << 'PYEOF'
import os
import re
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
targets = list((repo_root / "tooling").glob("*.sh")) + [repo_root / "verify-local.sh"]

pattern = re.compile(r"\bclaimed_by_agent\b(?!_id)")
updated_files = 0

for path in targets:
    if not path.exists() or path.name == "fix-claimed-by-agent-refs.sh":
        continue
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    changed_indices = []
    for idx, line in enumerate(lines):
        if pattern.search(line):
            lines[idx] = pattern.sub("claimed_by_agent_id", line)
            changed_indices.append(idx + 1)

    if changed_indices:
        path.write_text("".join(lines), encoding="utf-8")
        updated_files += 1
        print(f"[OK] {path.relative_to(repo_root)} -> updated lines {changed_indices}")

if updated_files == 0:
    print("[INFO] No remaining bare claimed_by_agent references found in scripts.")
PYEOF

echo -e "${GREEN}[OK]${NC} Script scan and patch complete."