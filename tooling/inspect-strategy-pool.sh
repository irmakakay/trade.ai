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

step "1/4 strategy_pool Schema & Total Count"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" << 'SQL'
\d strategy_pool
SELECT COUNT(*) AS total_rows FROM strategy_pool;
SQL

step "2/4 Breakdown by Status & Strategy / Profile Columns"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" << 'SQL'
DO $$
DECLARE
  has_status boolean;
  has_strategy_code boolean;
  has_profile boolean;
  has_created_at boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'strategy_pool' AND column_name = 'status'
  ) INTO has_status;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'strategy_pool' AND column_name = 'strategy_code'
  ) INTO has_strategy_code;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'strategy_pool' AND column_name = 'profile'
  ) INTO has_profile;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'strategy_pool' AND column_name = 'created_at'
  ) INTO has_created_at;

  IF has_status THEN
    RAISE NOTICE '--- Counts by status ---';
    PERFORM 1;
  END IF;
END $$;

SELECT COALESCE(status, '<no_status>') AS status, COUNT(*) AS row_count
FROM (
  SELECT CASE WHEN EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'strategy_pool' AND column_name = 'status'
  ) THEN (to_jsonb(sp)->>'status') ELSE NULL END AS status
  FROM strategy_pool sp
) sub
GROUP BY 1
ORDER BY row_count DESC;
SQL

step "3/4 Sample Rows & Key Distribution (JSONB Inspection)"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" << 'SQL'
SELECT
  to_jsonb(sp)->>'id' AS id,
  to_jsonb(sp)->>'status' AS status,
  to_jsonb(sp)->>'strategy_code' AS strategy_code,
  to_jsonb(sp)->>'profile' AS profile,
  to_jsonb(sp)->>'sl' AS sl,
  to_jsonb(sp)->>'tp' AS tp,
  to_jsonb(sp)->>'created_at' AS created_at
FROM strategy_pool sp
ORDER BY to_jsonb(sp)->>'id' DESC NULLS LAST
LIMIT 25;
SQL

step "4/4 Codebase References to strategy_pool, Pool Caps, & Seeding/Reset Logic"
python3 - << 'PYEOF'
import os
import re
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
skip_dirs = {".git", "node_modules", "bin", "obj", ".venv", "venv", "__pycache__"}
pattern = re.compile(r"(strategy_pool|pool_size|max_pool|target_pool|seed.*pool|evolve.*pool|AGGR#1)", re.IGNORECASE)

hits = 0
for root_str, dirs, files in os.walk(repo_root):
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for fname in sorted(files):
        if fname == "inspect-strategy-pool.sh":
            continue
        if not fname.endswith((".cs", ".py", ".sql", ".sh", ".ts", ".tsx", ".js", ".jsx", ".json", ".yaml", ".yml")):
            continue
        fpath = Path(root_str) / fname
        try:
            lines = fpath.read_text(encoding="utf-8").splitlines()
        except Exception:
            continue

        file_hits = []
        for idx, line in enumerate(lines, start=1):
            if pattern.search(line):
                file_hits.append((idx, line.strip()))
        if file_hits:
            hits += len(file_hits)
            print(f"\n[{fpath.relative_to(repo_root)}]")
            for idx, text in file_hits[:15]:
                print(f"  L{idx}: {text}")
            if len(file_hits) > 15:
                print(f"  ... ({len(file_hits) - 15} more lines)")

print(f"\n[SUMMARY] Total matching lines across codebase: {hits}")
PYEOF

ok "Read-only strategy_pool diagnostic complete"