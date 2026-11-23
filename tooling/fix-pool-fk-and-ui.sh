#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

export REPO_ROOT
export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain
export COMPOSE_DOCKER_CLI_BUILD=1

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step() { echo -e "\n${CYAN}━━━ [$(date +%H:%M:%S)] $1 ━━━${NC}"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

PG_USER="${POSTGRES_USER:-quant}"
PG_DB="${POSTGRES_DB:-quantcore}"

step "1/4 Fixing ForeignKeyViolation in src/quant_nn_worker/main.py"
python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
worker_path = repo_root / "src/quant_nn_worker/main.py"
code = worker_path.read_text(encoding="utf-8")

old_del = '"DELETE FROM strategy_pool WHERE profile_key = %s AND status = \'AVAILABLE\';"'
new_del = (
    '"DELETE FROM strategy_pool sp WHERE sp.profile_key = %s AND sp.status = \'AVAILABLE\' '
    'AND NOT EXISTS (SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id);"'
)

if old_del in code:
    code = code.replace(old_del, new_del)
    worker_path.write_text(code, encoding="utf-8")
    print("[OK] Guarded strategy_pool DELETE in main.py against trading_history FK")
else:
    print("[INFO] Exact DELETE string not matched; inspecting lines 115-145 of main.py")
    lines = code.splitlines()
    for idx in range(114, min(len(lines), 145)):
        print(f"  {idx+1:4d}: {lines[idx]}")
PYEOF

step "2/4 Capping Pool Grid Items in LiveDashboard.tsx"
python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
ui_path = repo_root / "src/quant-ui/src/components/LiveDashboard.tsx"
if ui_path.exists():
    code = ui_path.read_text(encoding="utf-8")
    old_map = "(summary?.pool_state ?? []).map((s, idx) => {"
    new_map = "(summary?.pool_state ?? []).slice(0, 18).map((s, idx) => {"
    if old_map in code:
        code = code.replace(old_map, new_map, 1)
        ui_path.write_text(code, encoding="utf-8")
        print("[OK] Capped LiveDashboard pool_state grid render to .slice(0, 18)")
    else:
        print("[INFO] pool_state map pattern not changed")
PYEOF

step "3/4 Pruning Unreferenced AVAILABLE Rows in PostgreSQL"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" << 'SQL'
WITH ranked_avail AS (
  SELECT
    pool_instance_id,
    ROW_NUMBER() OVER (
      PARTITION BY profile_key
      ORDER BY created_at DESC NULLS LAST, replica_index ASC, pool_instance_id DESC
    ) AS rn
  FROM strategy_pool sp
  WHERE sp.status = 'AVAILABLE'
    AND NOT EXISTS (
      SELECT 1 FROM trading_history th WHERE th.pool_instance_id = sp.pool_instance_id
    )
)
DELETE FROM strategy_pool sp
USING ranked_avail ra
WHERE sp.pool_instance_id = ra.pool_instance_id
  AND ra.rn > 6;

SELECT profile_key, status, COUNT(*) AS cnt
FROM strategy_pool
GROUP BY profile_key, status
ORDER BY profile_key, status;
SQL
ok "Pruned unreferenced AVAILABLE pool rows"

step "4/4 Rebuilding & Restarting nn-worker (and UI if present)"
dc build nn-worker
dc up -d --force-recreate nn-worker
if dc ps --services 2>/dev/null | grep -qx "quant-ui"; then
  dc build quant-ui
  dc up -d --force-recreate quant-ui
fi
sleep 2
dc logs --tail=20 nn-worker || true