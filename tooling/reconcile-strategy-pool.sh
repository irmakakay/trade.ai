#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

export REPO_ROOT

GREEN='\033[0;32m'
RED='\033[0;31m'
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

step "1/4 Inspecting strategy_pool Schema & Sample Data"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -c "\d strategy_pool"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -c "SELECT * FROM strategy_pool LIMIT 10;"

step "2/4 Normalizing strategy_pool Columns & Resetting Stale Claims"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" << 'SQL'
DO $$
DECLARE
  has_claimed_by_agent boolean;
  has_claimed_at boolean;
  has_status boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'strategy_pool' AND column_name = 'claimed_by_agent_id'
  ) INTO has_claimed_by_agent;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'strategy_pool' AND column_name = 'claimed_at'
  ) INTO has_claimed_at;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'strategy_pool' AND column_name = 'status'
  ) INTO has_status;

  IF NOT has_claimed_by_agent THEN
    ALTER TABLE strategy_pool ADD COLUMN claimed_by_agent_id TEXT NULL;
  END IF;

  IF NOT has_claimed_at THEN
    ALTER TABLE strategy_pool ADD COLUMN claimed_at TIMESTAMPTZ NULL;
  END IF;

  IF has_status THEN
    UPDATE strategy_pool
       SET status = 'AVAILABLE',
           claimed_by_agent_id = NULL,
           claimed_at = NULL
     WHERE status IS DISTINCT FROM 'AVAILABLE'
        OR claimed_by_agent_id IS NOT NULL
        OR claimed_at IS NOT NULL;
  ELSE
    UPDATE strategy_pool
       SET claimed_by_agent_id = NULL,
           claimed_at = NULL
     WHERE claimed_by_agent_id IS NOT NULL
        OR claimed_at IS NOT NULL;
  END IF;
END $$;
SQL
ok "strategy_pool normalized and stale claims cleared"

step "3/4 Auditing & Aligning Codebase Entities / Queries Referencing strategy_pool"
python3 - << 'PYEOF'
import os
import re
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
skip_dirs = {".git", "node_modules", "bin", "obj", ".venv", "venv", "__pycache__"}

matches = []
for root_str, dirs, files in os.walk(repo_root):
    dirs[:] = [d for d in dirs if d not in skip_dirs]
    for fname in files:
        if not fname.endswith((".cs", ".py", ".sql", ".sh")):
            continue
        if fname == "reconcile-strategy-pool.sh":
            continue
        fpath = Path(root_str) / fname
        try:
            content = fpath.read_text(encoding="utf-8")
        except Exception:
            continue

        if "strategy_pool" in content or "claimed_by_agent_id" in content:
            matches.append(fpath)

print(f"[INFO] Found {len(matches)} file(s) referencing strategy_pool or claimed_by_agent_id:")
for m in matches:
    print(f"  - {m.relative_to(repo_root)}")

# Ensure C# entity/record models that map strategy_pool treat ClaimedByAgent & ClaimedAt as nullable
for fpath in matches:
    if fpath.suffix != ".cs":
        continue
    original = fpath.read_text(encoding="utf-8")
    updated = original

    # Make non-nullable string/DateTime/DateTimeOffset properties for ClaimedByAgent / ClaimedAt nullable
    updated = re.sub(
        r'(\bpublic\s+string)\s+(ClaimedByAgent\s*\{)',
        r'\1? \2',
        updated,
    )
    updated = re.sub(
        r'(\bpublic\s+DateTime(?:Offset)?)\s+(ClaimedAt\s*\{)',
        r'\1? \2',
        updated,
    )

    # Guard against null ClaimedByAgent in C# comparisons/reads
    updated = updated.replace("row.ClaimedByAgent.Trim()", "(row.ClaimedByAgent ?? string.Empty).Trim()")

    if updated != original:
        fpath.write_text(updated, encoding="utf-8")
        print(f"[OK] Hardened nullable claim properties in {fpath.relative_to(repo_root)}")
PYEOF

step "4/4 Verifying Normalized Table & Re-running normalize-db.sh"
dc exec -T postgres psql -U "$PG_USER" -d "$PG_DB" \
  -c "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_name = 'strategy_pool' ORDER BY ordinal_position;"

if [[ -x "$REPO_ROOT/tooling/normalize-db.sh" ]]; then
  "$REPO_ROOT/tooling/normalize-db.sh"
  ok "tooling/normalize-db.sh succeeded"
fi