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

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

PG_USER="${POSTGRES_USER:-quant}"
PG_DB="${POSTGRES_DB:-quantcore}"

echo -e "${CYAN}━━━ [1/3] Hard-Pruning Excess AVAILABLE Rows Across All Profiles ━━━${NC}"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" << 'SQL'
WITH ranked AS (
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
USING ranked r
WHERE sp.pool_instance_id = r.pool_instance_id
  AND r.rn > 6;

SELECT profile_key, status, COUNT(*) AS cnt
FROM strategy_pool
GROUP BY profile_key, status
ORDER BY profile_key, status;
SQL

echo -e "${CYAN}━━━ [2/3] Inspecting AgentEpisodeEndpoints.cs pool_state Query ━━━${NC}"
nl -ba "$REPO_ROOT/src/QuantCore.Api/Endpoints/AgentEpisodeEndpoints.cs" | sed -n '165,195p' || true

echo -e "${CYAN}━━━ [3/3] Rebuilding UI & API Services (If Defined in Compose) ━━━${NC}"
for svc in quant-ui quant-core-api api; do
  if dc config --services 2>/dev/null | grep -qx "$svc"; then
    echo -e "${YELLOW}[INFO]${NC} Rebuilding & recreating service: $svc"
    dc build "$svc"
    dc up -d --force-recreate "$svc"
  fi
done

echo -e "${GREEN}[OK]${NC} Pool pruned and build/restart checks complete. Hard-refresh the UI (Cmd+Shift+R)."