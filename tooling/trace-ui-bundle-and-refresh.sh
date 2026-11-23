#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

PG_USER="${POSTGRES_USER:-quant}"
PG_DB="${POSTGRES_DB:-quantcore}"

echo -e "${CYAN}━━━ [1/4] Compose Services & Exposed Ports ━━━${NC}"
dc --profile agents ps -a || true
grep -n -C 3 "ports:\|quant-ui\|3000\|5173\|8080\|80:" "$REPO_ROOT/docker-compose.yml" || true

echo -e "${CYAN}━━━ [2/4] Check refresh-dockers.sh for Pool Seeding / UI Steps ━━━${NC}"
grep -n -C 4 "strategy_pool\|INSERT INTO\|quant-ui\|normalize-db" "$REPO_ROOT/tooling/refresh-dockers.sh" || true

echo -e "${CYAN}━━━ [3/4] Verify .slice(0, 18) in LiveDashboard.tsx & Running Host UI Processes ━━━${NC}"
grep -n -C 2 "slice(0, 18)" "$REPO_ROOT/src/quant-ui/src/components/LiveDashboard.tsx" || echo "[WARN] .slice(0, 18) not found in LiveDashboard.tsx"
ps aux | grep -E "vite|next|node|npm|pnpm|yarn" | grep -v grep || true

echo -e "${CYAN}━━━ [4/4] Current strategy_pool Row Count Right Now ━━━${NC}"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -c "SELECT status, COUNT(*) FROM strategy_pool GROUP BY status ORDER BY status;"