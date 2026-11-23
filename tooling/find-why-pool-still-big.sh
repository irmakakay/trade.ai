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

echo -e "${CYAN}━━━ [1/4] Live strategy_pool Counts by profile_key & status ━━━${NC}"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" << 'SQL'
SELECT profile_key, status, COUNT(*) AS cnt
FROM strategy_pool
GROUP BY profile_key, status
ORDER BY profile_key, status;
SQL

echo -e "${CYAN}━━━ [2/4] Where pool_state Is Constructed in API / Backend ━━━${NC}"
grep -rn "pool_state\|PoolState\|strategy_pool" "$REPO_ROOT/src" || true

echo -e "${CYAN}━━━ [3/4] All .map( in LiveDashboard.tsx ━━━${NC}"
nl -ba "$REPO_ROOT/src/quant-ui/src/components/LiveDashboard.tsx" | grep -n -C 3 "\.map(" || true

echo -e "${CYAN}━━━ [4/4] Live /api/v1/episodes/summary pool_state Length (if API is reachable) ━━━${NC}"
python3 - << 'PYEOF'
import json
import urllib.request

for url in ("http://localhost:8080/api/v1/episodes/summary", "http://localhost:5000/api/v1/episodes/summary", "http://localhost:8000/api/v1/episodes/summary"):
    try:
        with urllib.request.urlopen(url, timeout=2) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            pool = data.get("pool_state")
            print(f"{url} -> pool_state type={type(pool).__name__}, len={len(pool) if isinstance(pool, list) else 'N/A'}")
            break
    except Exception:
        continue
else:
    print("[INFO] Could not reach /api/v1/episodes/summary on common localhost ports; check UI network tab if needed.")
PYEOF