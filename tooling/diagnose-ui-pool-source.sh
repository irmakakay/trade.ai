#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

export REPO_ROOT

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

PG_USER="${POSTGRES_USER:-quant}"
PG_DB="${POSTGRES_DB:-quantcore}"

echo -e "${CYAN}━━━ [1/3] Current strategy_pool Counts by profile_key & status ━━━${NC}"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" << 'SQL'
SELECT profile_key, status, COUNT(*) AS cnt
FROM strategy_pool
GROUP BY profile_key, status
ORDER BY profile_key, status;

SELECT COUNT(*) AS total_rows FROM strategy_pool;
SQL

echo -e "${CYAN}━━━ [2/3] How LiveDashboard.tsx Loads Pool Items ━━━${NC}"
python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
ui_file = repo_root / "src/quant-ui/src/components/LiveDashboard.tsx"
if ui_file.exists():
    lines = ui_file.read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines, start=1):
        low = line.lower()
        if any(k in low for k in ("pool", "strategy_pool", "evolved", "fetch", "websocket", "/api/", "slice(", "filter(")):
            start = max(1, i - 2)
            end = min(len(lines), i + 4)
            print(f"--- Lines {start}-{end} ---")
            for j in range(start, end + 1):
                mark = ">>" if j == i else "  "
                print(f"{mark} {j:4d}: {lines[j-1]}")
PYEOF

echo -e "${CYAN}━━━ [3/3] Recent nn-worker & Pool Seeder Logs ━━━${NC}"
dc logs --tail=30 nn-worker || true