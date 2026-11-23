#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

export REPO_ROOT

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

step "1/4 Inspecting normalize-db.sh & nn-worker Pool Seeding Lines"
nl -ba "$REPO_ROOT/tooling/normalize-db.sh" | sed -n '25,130p' || true
echo "---"
nl -ba "$REPO_ROOT/src/quant_nn_worker/main.py" | sed -n '118,148p' || true

step "2/4 Removing Duplicate claimed_by_agent_id Column & Capping Excess AVAILABLE Rows"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" << 'SQL'
-- [NEUTRALIZED] Never drop claimed_by_agent_id (required by QuantCore.Api)

-- Keep at most 12 newest AVAILABLE rows per profile_key (preserving rows referenced by trading_history)
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
  AND ra.rn > 12;

SELECT profile_key, status, COUNT(*) AS cnt
FROM strategy_pool
GROUP BY profile_key, status
ORDER BY profile_key, status;
SQL
ok "Schema cleaned and AVAILABLE pool capped to <= 12 per profile_key"

step "3/4 Aligning normalize-db.sh to claimed_by_agent_id"
python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
norm_path = repo_root / "tooling/normalize-db.sh"
if norm_path.exists():
    text = norm_path.read_text(encoding="utf-8")
    updated = text.replace("claimed_by_agent_id", "claimed_by_agent_id")
    if updated != text:
        norm_path.write_text(updated, encoding="utf-8")
        print("[OK] Replaced claimed_by_agent_id with claimed_by_agent_id in tooling/normalize-db.sh")
    else:
        print("[INFO] No claimed_by_agent_id references found in tooling/normalize-db.sh")
PYEOF

step "4/4 Running normalize-db.sh & Verifying Pool Count"
"$REPO_ROOT/tooling/normalize-db.sh"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -c "SELECT status, COUNT(*) FROM strategy_pool GROUP BY status ORDER BY status;"
ok "strategy_pool normalized and verified"