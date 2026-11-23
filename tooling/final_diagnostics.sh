cat << 'EOF' > collect-trade-ai-diag.sh
#!/usr/bin/env bash
set +e

OUT_FILE="trade_ai_diag.txt"

redact() {
  sed -E \
    -e 's#(postgres(ql)?|amqp|amqps|redis|rediss)://[^/@[:space:]"'\'']+@#\1://***REDACTED***@#g' \
    -e 's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Ww][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Aa][Pp][Ii]_?[Kk][Ee][Yy])([[:space:]]*[:=][[:space:]]*)[^;[:space:]"'\'']+/\1\2***REDACTED***/g'
}

section() {
  printf "\n====================================================================\n"
  printf "### %s\n" "$1"
  printf "====================================================================\n"
}

run_report() {
  echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Working Dir: $(pwd)"

  section "1. HOST & GIT STATE"
  echo "--- Host Versions ---"
  dotnet --list-sdks 2>&1 || echo "dotnet not installed on host"
  dotnet --list-runtimes 2>&1 || true
  python3 --version 2>&1 || true
  docker --version 2>&1 || true
  docker compose version 2>&1 || true

  echo "--- Git Status & Recent Commits ---"
  git status -sb 2>&1 || echo "Not a git repo"
  git log -n 8 --oneline 2>&1 || true

  echo "--- Repo Layout (depth 3, noisy dirs excluded) ---"
  find . -maxdepth 3 \
    -not -path '*/.git*' \
    -not -path '*/node_modules*' \
    -not -path '*/bin*' \
    -not -path '*/obj*' \
    -not -path '*/__pycache__*' \
    -not -path '*/.venv*' \
    -not -path '*/venv*' \
    | sort

  section "2. DOCKER COMPOSE & CONTAINER HEALTH"
  echo "--- docker compose ps -a ---"
  docker compose ps -a 2>&1

  echo "--- Container Exit Codes / OOM / Restart Counts ---"
  for cid in $(docker compose ps -aq 2>/dev/null); do
    docker inspect --format '{{.Name}} | Image={{.Config.Image}} | Status={{.State.Status}} | ExitCode={{.State.ExitCode}} | OOMKilled={{.State.OOMKilled}} | Restarts={{.RestartCount}} | Error={{.State.Error}}' "$cid" 2>&1
  done

  echo "--- Compose Files (redacted) ---"
  for f in docker-compose*.yml docker-compose*.yaml compose*.yml compose*.yaml; do
    [ -f "$f" ] && { echo ">>> FILE: $f"; cat "$f" | redact; }
  done

  section "3. .NET PROJECTS, DOCKERFILES & DI WIRING"
  echo "--- global.json & .dockerignore ---"
  for f in $(find . -maxdepth 4 \( -name "global.json" -o -name ".dockerignore" \) -not -path '*/.git*'); do
    echo ">>> FILE: $f"
    cat "$f"
  done

  echo "--- *.csproj Files ---"
  for f in $(find . -maxdepth 5 -name "*.csproj" -not -path '*/obj/*' -not -path '*/bin/*'); do
    echo ">>> FILE: $f"
    cat "$f"
  done

  echo "--- All Dockerfiles ---"
  for f in $(find . -maxdepth 4 -iname "Dockerfile*" -not -path '*/.git*'); do
    echo ">>> FILE: $f"
    cat "$f"
  done

  echo "--- Program.cs & TelemetryExecutionGateway / Revolut / Npgsql Wiring ---"
  grep -rnE "TelemetryExecutionGateway|AddNpgsql|NpgsqlDataSource|Revolut|UseMiddleware|strategy_pool|execution_history|trading_history" \
    --include="*.cs" . 2>/dev/null | head -n 120

  for f in $(find . -maxdepth 5 -name "Program.cs" -not -path '*/obj/*' -not -path '*/bin/*'); do
    echo ">>> FILE: $f"
    cat "$f" | redact
  done

  section "4. PYTHON / NN-WORKER DEPENDENCIES & DB DRIVERS"
  echo "--- requirements.txt / pyproject.toml ---"
  for f in $(find . -maxdepth 4 \( -name "requirements*.txt" -o -name "pyproject.toml" \) -not -path '*/.venv/*' -not -path '*/venv/*'); do
    echo ">>> FILE: $f"
    cat "$f"
  done

  echo "--- Python DB Driver & Table References ---"
  grep -rnE "psycopg|postgresql://|asyncpg|sqlalchemy|strategy_pool|execution_history|trading_history|execution_feedback" \
    --include="*.py" --exclude-dir=".venv" --exclude-dir="venv" --exclude-dir="__pycache__" . 2>/dev/null | head -n 120

  echo "--- Live Python Packages Inside Running Python/Worker Containers ---"
  for cid in $(docker compose ps -q 2>/dev/null); do
    running=$(docker inspect --format '{{.State.Running}}' "$cid" 2>/dev/null)
    [ "$running" != "true" ] && continue
    cname=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null)
    if docker exec "$cid" sh -c 'command -v python3 || command -v python' >/dev/null 2>&1; then
      echo ">>> Container: $cname"
      docker exec "$cid" sh -c 'python3 --version 2>/dev/null || python --version; pip list 2>/dev/null | grep -iE "psycopg|torch|pika|aio|sqlalchemy|pydantic|fastapi|uvicorn|redis|alembic|numpy"' 2>&1
    fi
  done

  section "5. POSTGRESQL SCHEMA, FKs, BLOAT & LOCKS"
  PG_CID=""
  for cid in $(docker compose ps -q 2>/dev/null); do
    running=$(docker inspect --format '{{.State.Running}}' "$cid" 2>/dev/null)
    [ "$running" != "true" ] && continue
    img=$(docker inspect --format '{{.Config.Image}} {{.Name}}' "$cid" 2>/dev/null)
    if echo "$img" | grep -qiE "postgres|timescale"; then
      PG_CID="$cid"
      break
    fi
  done

  if [ -n "$PG_CID" ]; then
    PG_USER=$(docker exec "$PG_CID" sh -c 'echo "${POSTGRES_USER:-postgres}"')
    PG_DB=$(docker exec "$PG_CID" sh -c 'echo "${POSTGRES_DB:-postgres}"')
    echo "Detected Postgres Container: $PG_CID (user=$PG_USER, db=$PG_DB)"

    docker exec -i "$PG_CID" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=0 << 'SQL'
\echo '--- Databases ---'
\l

\echo '--- Table Sizes, Live & Dead Tuples ---'
SELECT
  relname AS table_name,
  n_live_tup,
  n_dead_tup,
  pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
  last_autovacuum
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC;

\echo '--- Public Schema Columns ---'
SELECT table_name, column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
ORDER BY table_name, ordinal_position;

\echo '--- Foreign Key Constraints ---'
SELECT
  tc.table_name AS source_table,
  kcu.column_name AS source_column,
  ccu.table_name AS target_table,
  ccu.column_name AS target_column,
  tc.constraint_name,
  rc.delete_rule
FROM information_schema.table_constraints AS tc
JOIN information_schema.key_column_usage AS kcu
  ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage AS ccu
  ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
JOIN information_schema.referential_constraints AS rc
  ON rc.constraint_name = tc.constraint_name AND rc.constraint_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
ORDER BY tc.table_name;

\echo '--- Indexes ---'
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;

\echo '--- strategy_pool Status Breakdown (if table exists) ---'
SELECT
  status,
  (claimed_by_agent_id IS NOT NULL) AS is_claimed,
  count(*) AS row_count
FROM strategy_pool
GROUP BY 1, 2
ORDER BY 1, 2;

\echo '--- Active / Waiting DB Connections & Locks ---'
SELECT pid, state, wait_event_type, wait_event, now() - query_start AS duration, left(query, 120) AS query
FROM pg_stat_activity
WHERE datname = current_database()
ORDER BY duration DESC NULLS LAST
LIMIT 20;
SQL
  else
    echo "No running PostgreSQL container detected via docker compose."
  fi

  section "6. RABBITMQ & REDIS STATUS"
  for cid in $(docker compose ps -q 2>/dev/null); do
    running=$(docker inspect --format '{{.State.Running}}' "$cid" 2>/dev/null)
    [ "$running" != "true" ] && continue
    img=$(docker inspect --format '{{.Config.Image}} {{.Name}}' "$cid" 2>/dev/null)

    if echo "$img" | grep -qi "rabbit"; then
      echo "--- RabbitMQ Queues ($img) ---"
      docker exec "$cid" rabbitmqctl list_queues name messages messages_ready messages_unacknowledged consumers 2>&1
    fi

    if echo "$img" | grep -qi "redis"; then
      echo "--- Redis Stats ($img) ---"
      docker exec "$cid" redis-cli dbsize 2>&1
      docker exec "$cid" redis-cli info memory 2>&1 | grep -E "used_memory_human|maxmemory_human|mem_fragmentation_ratio"
      docker exec "$cid" redis-cli --scan --count 25 2>&1 | head -n 25
    fi
  done

  section "7. ENV KEYS (NAMES ONLY) & EXISTING OPS SCRIPTS"
  for f in $(find . -maxdepth 3 -name ".env*" -not -path '*/.git*'); do
    echo ">>> ENV KEYS IN: $f"
    grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$f" | cut -d'=' -f1 | sort
  done

  echo "--- Maintenance Shell Scripts ---"
  for f in $(find . -maxdepth 3 -name "*.sh" -not -name "collect-trade-ai-diag.sh" -not -path '*/.git*'); do
    echo ">>> SCRIPT: $f"
    cat "$f" | redact
  done

  section "8. CONTAINER LOGS (LAST 100 LINES PER SERVICE)"
  for svc in $(docker compose config --services 2>/dev/null); do
    echo ">>> LOGS: $svc"
    docker compose logs --no-color --tail=100 "$svc" 2>&1 | redact
  done
}

run_report > "$OUT_FILE" 2>&1
echo "Diagnostics saved to $OUT_FILE ($(wc -l < "$OUT_FILE" | tr -d ' ') lines)."
echo "Copy to clipboard on macOS with: pbcopy < $OUT_FILE"
EOF

chmod +x collect-trade-ai-diag.sh && ./collect-trade-ai-diag.sh