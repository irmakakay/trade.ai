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

step "1/4 Inspecting LiveDashboard.tsx Pool Rendering & API Endpoints"
nl -ba "$REPO_ROOT/src/quant-ui/src/components/LiveDashboard.tsx" | sed -n '275,340p' || true
echo "--- API Pool Queries ---"
grep -rn "strategy_pool" "$REPO_ROOT/src/QuantCore.Api" || true

step "2/4 Trimming Excess AVAILABLE Rows in PostgreSQL (Keep Latest 12 per profile_key)"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" << 'SQL'
-- [NEUTRALIZED] Never drop claimed_by_agent_id (required by QuantCore.Api)

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

SELECT status, COUNT(*) AS row_count
FROM strategy_pool
GROUP BY status
ORDER BY status;
SQL
ok "PostgreSQL strategy_pool trimmed"

step "3/4 Checking Running Containers & Rebuilding UI if Needed"
dc --profile agents ps
if dc ps --services 2>/dev/null | grep -qx "quant-ui"; then
  info "Rebuilding & recreating quant-ui container so UI bundle reflects latest code..."
  dc build quant-ui
  dc up -d --force-recreate quant-ui
  ok "quant-ui rebuilt and recreated"
else
  info "No quant-ui service in compose (likely running via Vite/dev server on host); hard-refresh browser (Cmd+Shift+R)"
fi

step "4/4 Final Row Count Check"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -c "SELECT COUNT(*) AS remaining_pool_rows FROM strategy_pool;"