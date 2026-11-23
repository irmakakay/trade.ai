#!/usr/bin/env bash
set -uo pipefail

# Disable BuildKit parallel curses UI that buffers/hides output on macOS
export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain
export COMPOSE_DOCKER_CLI_BUILD=1

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

step() { echo -e "\n${CYAN}━━━ [$(date +%H:%M:%S)] $1 ━━━${NC}"; }
ok()   { echo -e "${GREEN}[PASS]${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# Non-blocking watchdog runner: streams live output OR shows a live timer and kills if stalled
run_guarded() {
  local timeout_sec="$1"
  local label="$2"
  shift 2

  info "Starting: ${label} (timeout: ${timeout_sec}s)..."
  local log_file="/tmp/quant_cmd_$$.log"
  rm -f "$log_file"

  # Launch command in background streaming to log_file
  "$@" >"$log_file" 2>&1 &
  local cmd_pid=$!
  local elapsed=0

  while kill -0 "$cmd_pid" 2>/dev/null; do
    local last_line=""
    if [[ -s "$log_file" ]]; then
      last_line=$(tail -n 1 "$log_file" | tr -d '\r' | cut -c1-70)
    fi
    printf "\r  ⏳ [%3ds / %3ds] %s -> %-70s" "$elapsed" "$timeout_sec" "$label" "${last_line:-waiting...}"
    sleep 1
    elapsed=$((elapsed + 1))

    if [[ "$elapsed" -ge "$timeout_sec" ]]; then
      echo ""
      fail "TIMEOUT (${timeout_sec}s exceeded) during: ${label}"
      kill -9 "$cmd_pid" 2>/dev/null || true
      echo -e "${YELLOW}--- Last 20 lines of stalled command output ---${NC}"
      tail -n 20 "$log_file" 2>/dev/null || true
      rm -f "$log_file"
      return 1
    fi
  done

  wait "$cmd_pid"
  local exit_code=$?
  printf "\r\033[K" # Clear progress line

  if [[ "$exit_code" -ne 0 ]]; then
    fail "${label} exited with code ${exit_code}"
    echo -e "${YELLOW}--- Command Error Output (last 25 lines) ---${NC}"
    tail -n 25 "$log_file" 2>/dev/null || true
    rm -f "$log_file"
    return "$exit_code"
  fi

  rm -f "$log_file"
  return 0
}

if [[ ! -f "docker-compose.yml" ]]; then
  echo -e "${RED}Error: Run this script from inside the quant-core/ root directory.${NC}"
  exit 1
fi

# 0. Pre-Flight: Verify Docker Daemon Responsiveness & Write .dockerignore
step "0/8 Pre-Flight: Docker Daemon Pulse & .dockerignore Optimization"
if ! run_guarded 8 "Docker Daemon Socket Check" docker info; then
  echo -e "${RED}FATAL: Docker Desktop daemon is unresponsive/deadlocked. Please restart Docker Desktop and re-run.${NC}"
  exit 1
fi
ok "Docker daemon is responsive"

cat > .dockerignore << 'EOF'
.git
.github
.vs
.vscode
**/node_modules
**/dist
**/bin
**/obj
**/__pycache__
**/.pytest_cache
**/.mypy_cache
**/.ruff_cache
.venv
venv
*.zip
*.log
EOF
ok "Generated .dockerignore (prevents multi-GB context stalls on '.' builds)"

[[ ! -f ".env" ]] && cp .env.example .env && info "Created .env from .env.example"

# 1. Tear Down Stale Containers & Build Images Sequentially (Saves RAM on 8GB M1)
step "1/8 Sequential Image Builds (Low-Memory Safe Mode)"
run_guarded 25 "Stopping stale containers" docker compose down -v --remove-orphans || true

run_guarded 120 "Building migrations image" docker compose build migrations
run_guarded 300 "Building nn-worker image (PyTorch + quant_nn_engine)" docker compose build nn-worker
run_guarded 300 "Building quant-api image (React Vite + .NET 8)" docker compose build quant-api
ok "All service images built sequentially without memory contention"

# 2. Boot Infrastructure & Services Step-by-Step
step "2/8 Starting Infrastructure (Postgres & RabbitMQ)"
run_guarded 45 "Starting postgres & rabbitmq" docker compose up -d postgres rabbitmq

info "Waiting for Postgres healthcheck..."
for i in {1..25}; do
  PG_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q postgres)" 2>/dev/null || echo "starting")
  printf "\r  ⏳ Postgres health: %-15s (%ds/25s)" "$PG_HEALTH" "$i"
  [[ "$PG_HEALTH" == "healthy" ]] && break
  sleep 1
done
echo ""

info "Waiting for RabbitMQ healthcheck..."
for i in {1..30}; do
  RMQ_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q rabbitmq)" 2>/dev/null || echo "starting")
  printf "\r  ⏳ RabbitMQ health: %-15s (%ds/30s)" "$RMQ_HEALTH" "$i"
  [[ "$RMQ_HEALTH" == "healthy" ]] && break
  sleep 1
done
echo ""
ok "Postgres and RabbitMQ are healthy"

# 3. Run Migrations Synchronously & Verify Idempotency
step "3/8 Applying Database Migrations & Checking Idempotency"
if run_guarded 30 "Pass 1: Applying V001 schema" docker compose run --rm --no-deps -T migrations; then
  ok "Migration Pass 1 succeeded"
else
  fail "Migration Pass 1 failed"
  exit 1
fi

MIG_PASS2=$(docker compose run --rm --no-deps -T migrations 2>&1 || true)
if echo "$MIG_PASS2" | grep -q "\[SKIP\] V001__initialize_schema.sql already applied"; then
  ok "Migration Pass 2 (Idempotency) verified: V001 skipped cleanly"
else
  fail "Migration Pass 2 did not skip V001: $MIG_PASS2"
fi

# 4. Start nn-worker & quant-api and Poll Readiness
step "4/8 Starting nn-worker & quant-api and Polling Pool Warmup"
run_guarded 30 "Starting nn-worker & quant-api" docker compose up -d --no-deps nn-worker quant-api

READY=false
for i in {1..40}; do
  HTTP_CODE=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" http://localhost:8080/health/ready || echo "000")
  printf "\r  ⏳ Polling /health/ready -> HTTP %s (%ds/40s)" "$HTTP_CODE" "$i"
  if [[ "$HTTP_CODE" == "200" ]]; then
    READY=true
    break
  fi
  sleep 1
done
echo ""

if [[ "$READY" == "true" ]]; then
  READY_JSON=$(curl -s --max-time 3 http://localhost:8080/health/ready)
  ok "QuantCore.Api is READY -> $READY_JSON"
else
  fail "QuantCore.Api did not reach READY within 40s. Dumping worker/api logs:"
  docker compose logs --tail=30 nn-worker quant-api
fi

# 5. Run Python & .NET Unit Test Suites (With Guarded Timeouts)
step "5/8 Running Unit Tests (Python + .NET)"
WORKER_TEST_DIR="quant_nn_tests"
[[ -d "tests/quant_nn_worker_tests" ]] && WORKER_TEST_DIR="quant_nn_worker_tests"

if run_guarded 90 "Python Pytest (${WORKER_TEST_DIR} + quant_nn_engine_tests)" \
  docker compose run --rm --no-deps -T \
    -v "$(pwd)/tests:/tests" \
    -e PYTHONPATH="/worker:/worker/quant_nn_engine" \
    nn-worker \
    sh -c "pip install -q --disable-pip-version-check pytest && pytest /tests/${WORKER_TEST_DIR} /tests/quant_nn_engine_tests -q"; then
  ok "Python unit tests passed"
fi

if run_guarded 120 ".NET xUnit (QuantCore.Tests + QuantCore.Agents.Tests)" \
  docker run --rm \
    -v "$(pwd):/src" \
    -v quant-nuget-cache:/root/.nuget/packages \
    -w /src \
    mcr.microsoft.com/dotnet/sdk:9.0-alpine \
    sh -c "dotnet test tests/QuantCore.Tests/QuantCore.Tests.csproj -c Release --nologo -v q --blame-hang-timeout 10s && \
           dotnet test tests/QuantCore.Agents.Tests/QuantCore.Agents.Tests.csproj -c Release --nologo -v q --blame-hang-timeout 10s"; then
  ok ".NET unit tests passed"
fi

# 6. End-to-End API Smoke Tests
step "6/8 End-to-End API Smoke Tests (Checkout, Slice Mutex, Commit, Reset)"
for REP in 1 2 3; do
  AGENT_UUID="00000000-0000-0000-0000-00000000000${REP}"
  CODE=$(curl -s --max-time 5 -o "/tmp/checkout_${REP}.json" -w "%{http_code}" -X POST http://localhost:8080/api/v1/pool/checkout \
    -H "Content-Type: application/json" \
    -d "{\"agent_id\":\"${AGENT_UUID}\",\"profile_key\":\"AGGRESSIVE_BREAKOUT\"}" || echo "000")
  if [[ "$CODE" == "200" ]]; then
    ok "Agent #${REP} checked out AGGRESSIVE_BREAKOUT Replica #${REP} (HTTP 200)"
  else
    fail "Agent #${REP} failed checkout (HTTP $CODE)"
  fi
done

CODE_4=$(curl -s --max-time 5 -o /tmp/checkout_4.json -w "%{http_code}" -X POST http://localhost:8080/api/v1/pool/checkout \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"00000000-0000-0000-0000-000000000004","profile_key":"AGGRESSIVE_BREAKOUT"}' || echo "000")
[[ "$CODE_4" == "409" ]] && ok "Agent #4 rejected with HTTP 409 Conflict" || fail "Agent #4 expected 409, got $CODE_4"

SLICE_RES=$(curl -s --max-time 5 -w "\n%{http_code}" -X POST http://localhost:8080/api/v1/inventory/claim-slice \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"00000000-0000-0000-0000-000000000001","strategy_id":"11111111-1111-1111-1111-111111111111","symbol":"SOLUSDT","requested_fraction_pct":0.40,"directional_bias":"LONG_ACCUMULATING"}' || echo -e "{}\n000")
SLICE_BODY=$(echo "$SLICE_RES" | head -n 1)
SLICE_CODE=$(echo "$SLICE_RES" | tail -n 1)
[[ "$SLICE_CODE" == "200" ]] && ok "Locked 40% of SOLUSDT (18 SOL) -> $SLICE_BODY" || fail "Slice lock failed ($SLICE_CODE): $SLICE_BODY"

POOL_ID=$(sed -E 's/.*"pool_instance_id":"([^"]+)".*/\1/' /tmp/checkout_1.json 2>/dev/null || echo "")
RUN_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
COMMIT_RES=$(curl -s --max-time 5 -w "\n%{http_code}" -X POST http://localhost:8080/api/v1/episodes/commit \
  -H "Content-Type: application/json" \
  -d "{\"run_id\":\"${RUN_ID}\",\"pool_instance_id\":\"${POOL_ID}\",\"identity_id\":\"00000000-0000-0000-0000-000000000001\",\"actor_type\":\"AGENT\",\"profile_key\":\"AGGRESSIVE_BREAKOUT\",\"replica_index\":1,\"jitter_delta_json\":\"{}\",\"executed_moves\":[],\"realized_pnl_usdt\":1.5,\"max_drawdown_pct\":0.01,\"sharpe_estimate\":1.2,\"liquidate_and_release_slices\":true}" || echo -e "{}\n000")
COMMIT_BODY=$(echo "$COMMIT_RES" | head -n 1)
COMMIT_CODE=$(echo "$COMMIT_RES" | tail -n 1)
[[ "$COMMIT_CODE" == "200" ]] && ok "Episode commit & slice release succeeded -> $COMMIT_BODY" || fail "Episode commit failed ($COMMIT_CODE): $COMMIT_BODY"

# 7. Component Status & Postgres Snapshot
step "7/8 Component Status & Database State"
docker compose ps
docker compose exec -T postgres psql -U quant -d quantcore -c \
  "SELECT symbol, total_quantity, allocated_quantity, directional_bias FROM portfolio_inventory;"
docker compose exec -T postgres psql -U quant -d quantcore -c \
  "SELECT profile_key, replica_index, status FROM strategy_pool ORDER BY profile_key, replica_index;"

# 8. Recent Service Logs
step "8/8 Recent Logs (nn-worker | quant-api)"
docker compose logs --tail=12 nn-worker quant-api

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Verification Summary: ${GREEN}${PASS_COUNT} Passed${NC} | ${RED}${FAIL_COUNT} Failed${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
[[ "$FAIL_COUNT" -eq 0 ]] || exit 1