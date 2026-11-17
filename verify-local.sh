#!/usr/bin/env bash
set -uo pipefail

# Colors & Formatting
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

step() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
ok()   { echo -e "${GREEN}[PASS]${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

if [[ ! -f "docker-compose.yml" ]]; then
  echo -e "${RED}Error: Run this script from inside the quant-core/ root directory.${NC}"
  exit 1
fi

[[ ! -f ".env" ]] && cp .env.example .env && info "Created .env from .env.example"

# 1. Clean & Build Containers
step "1/7 Building & Starting Docker Compose Stack"
docker compose down -v --remove-orphans >/dev/null 2>&1 || true
if ! docker compose up -d --build; then
  fail "docker compose up -d --build failed"
  exit 1
fi

# 2. Wait for One-Shot Migrations & Verify Idempotency
step "2/7 Verifying Database Migrations & Idempotency"
info "Waiting for migrations container to complete..."
MIG_CID=""
for i in {1..30}; do
  MIG_CID=$(docker compose ps -a -q migrations 2>/dev/null || true)
  if [[ -n "$MIG_CID" ]]; then
    MIG_STATE=$(docker inspect -f '{{.State.Status}}' "$MIG_CID" 2>/dev/null || echo "waiting")
    if [[ "$MIG_STATE" == "exited" ]]; then
      break
    fi
  fi
  sleep 1
done

MIG_EXIT=$(docker inspect -f '{{.State.ExitCode}}' "$MIG_CID" 2>/dev/null || echo "1")
if [[ "$MIG_EXIT" == "0" ]]; then
  ok "Initial migration V001 applied cleanly (Exit Code 0)"
else
  fail "Migrations container failed with Exit Code $MIG_EXIT"
  docker compose logs migrations
fi

info "Re-running migrations container (--no-deps -T) to verify idempotency..."
MIG_OUT=$(docker compose run --rm --no-deps -T migrations 2>&1 || true)
if echo "$MIG_OUT" | grep -q "\[SKIP\] V001__initialize_schema.sql already applied"; then
  ok "Idempotency verified: V001 skipped with matching SHA-256 checksum"
else
  fail "Migration idempotency check failed: $MIG_OUT"
fi

# 3. Wait for API Readiness (Pool Warmup via RabbitMQ -> Python NN Worker -> Postgres)
step "3/7 Waiting for Pool Warmup & API Readiness (http://localhost:8080/health/ready)"
READY=false
for i in {1..40}; do
  HTTP_CODE=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" http://localhost:8080/health/ready || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    READY=true
    break
  fi
  sleep 1
done

if [[ "$READY" == "true" ]]; then
  READY_JSON=$(curl -s --max-time 3 http://localhost:8080/health/ready)
  ok "QuantCore.Api is READY -> $READY_JSON"
else
  fail "QuantCore.Api did not reach READY state within 40s"
  docker compose logs --tail=25 nn-worker quant-api
fi

# 4. Run Unit Test Suites (.NET xUnit + Python Pytest)
step "4/7 Running Unit & Contract Parity Tests"

# Auto-detect whether worker tests folder is named quant_nn_tests or quant_nn_worker_tests
WORKER_TEST_DIR="quant_nn_tests"
[[ -d "tests/quant_nn_worker_tests" ]] && WORKER_TEST_DIR="quant_nn_worker_tests"

info "Running Python Pytest suites (${WORKER_TEST_DIR} + quant_nn_engine_tests) in single container pass..."
if docker compose run --rm --no-deps -T \
  -v "$(pwd)/tests:/tests" \
  -v "$(pwd)/src/quant_nn_engine:/engine" \
  -e PYTHONPATH="/worker:/engine" \
  nn-worker \
  sh -c "pip install -q --disable-pip-version-check pytest pytest-cov && pytest /tests/${WORKER_TEST_DIR} /tests/quant_nn_engine_tests -q"; then
  ok "Python NN Worker & NN Engine unit tests passed"
else
  fail "Python unit tests failed"
fi

info "Running .NET 8 xUnit suites (QuantCore.Tests + QuantCore.Agents.Tests) with 15s hang guard..."
if docker run --rm \
  -v "$(pwd):/src" \
  -v quant-nuget-cache:/root/.nuget/packages \
  -w /src \
  mcr.microsoft.com/dotnet/sdk:8.0-alpine \
  sh -c "dotnet test tests/QuantCore.Tests/QuantCore.Tests.csproj -c Release --nologo -v q --blame-hang-timeout 15s && \
         dotnet test tests/QuantCore.Agents.Tests/QuantCore.Agents.Tests.csproj -c Release --nologo -v q --blame-hang-timeout 15s"; then
  ok ".NET 8 xUnit (QuantCore.Tests + QuantCore.Agents.Tests) passed"
else
  fail ".NET 8 xUnit tests failed or timed out"
fi

# 5. Live End-to-End Smoke Tests (Pool Checkout K-Replication & Inventory Slice Mutex)
step "5/7 End-to-End Smoke Tests: K-Replica Pool Checkout & Share-Slice Lock"

for REP in 1 2 3; do
  AGENT_UUID="00000000-0000-0000-0000-00000000000${REP}"
  CODE=$(curl -s --max-time 5 -o "/tmp/checkout_${REP}.json" -w "%{http_code}" -X POST http://localhost:8080/api/v1/pool/checkout \
    -H "Content-Type: application/json" \
    -d "{\"agent_id\":\"${AGENT_UUID}\",\"profile_key\":\"AGGRESSIVE_BREAKOUT\"}")
  if [[ "$CODE" == "200" ]]; then
    ok "Agent #${REP} checked out AGGRESSIVE_BREAKOUT Replica #${REP} (HTTP 200)"
  else
    fail "Agent #${REP} failed checkout (HTTP $CODE)"
  fi
done

CODE_4=$(curl -s --max-time 5 -o /tmp/checkout_4.json -w "%{http_code}" -X POST http://localhost:8080/api/v1/pool/checkout \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"00000000-0000-0000-0000-000000000004","profile_key":"AGGRESSIVE_BREAKOUT"}')
if [[ "$CODE_4" == "409" ]]; then
  ok "Agent #4 (K+1) deterministically rejected with HTTP 409 Conflict (Pool Exhausted)"
else
  fail "Agent #4 expected HTTP 409 but got HTTP $CODE_4"
fi

SLICE_RES=$(curl -s --max-time 5 -w "\n%{http_code}" -X POST http://localhost:8080/api/v1/inventory/claim-slice \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id":"00000000-0000-0000-0000-000000000001",
    "strategy_id":"11111111-1111-1111-1111-111111111111",
    "symbol":"SOLUSDT",
    "requested_fraction_pct":0.40,
    "directional_bias":"LONG_ACCUMULATING"
  }')
SLICE_BODY=$(echo "$SLICE_RES" | head -n 1)
SLICE_CODE=$(echo "$SLICE_RES" | tail -n 1)

if [[ "$SLICE_CODE" == "200" ]] && echo "$SLICE_BODY" | grep -q '"reserved_quantity":18'; then
  ok "Inventory Slice Mutex locked 40% of SOLUSDT (18.0 SOL) & released lock -> $SLICE_BODY"
else
  fail "Inventory Slice Mutex test failed ($SLICE_CODE): $SLICE_BODY"
fi

POOL_ID=$(sed -E 's/.*"pool_instance_id":"([^"]+)".*/\1/' /tmp/checkout_1.json)
RUN_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
COMMIT_RES=$(curl -s --max-time 5 -w "\n%{http_code}" -X POST http://localhost:8080/api/v1/episodes/commit \
  -H "Content-Type: application/json" \
  -d "{\"run_id\":\"${RUN_ID}\",\"pool_instance_id\":\"${POOL_ID}\",\"identity_id\":\"00000000-0000-0000-0000-000000000001\",\"actor_type\":\"AGENT\",\"profile_key\":\"AGGRESSIVE_BREAKOUT\",\"replica_index\":1,\"jitter_delta_json\":\"{}\",\"executed_moves\":[],\"realized_pnl_usdt\":1.5,\"max_drawdown_pct\":0.01,\"sharpe_estimate\":1.2,\"liquidate_and_release_slices\":true}")
COMMIT_BODY=$(echo "$COMMIT_RES" | head -n 1)
COMMIT_CODE=$(echo "$COMMIT_RES" | tail -n 1)

if [[ "$COMMIT_CODE" == "200" ]] && echo "$COMMIT_BODY" | grep -q '"committed":true' && echo "$COMMIT_BODY" | grep -q '"slices_released":1'; then
  ok "Episode commit persisted trading_history & released Agent #1 slice -> $COMMIT_BODY"
else
  fail "Episode commit failed ($COMMIT_CODE): $COMMIT_BODY"
fi

ALLOCATED_AFTER=$(docker compose exec -T postgres psql -U quant -d quantcore -tA -c \
  "SELECT allocated_quantity FROM portfolio_inventory WHERE symbol = 'SOLUSDT';" | tr -d '[:space:]')
if [[ "$ALLOCATED_AFTER" == "0.0000000000" ]]; then
  ok "SOLUSDT allocated_quantity returned to 0 after liquidate-and-release"
else
  fail "SOLUSDT allocated_quantity expected 0.0000000000 but got '$ALLOCATED_AFTER'"
fi

RESET_CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" -X POST http://localhost:8080/api/v1/episodes/reset \
  -H "Content-Type: application/json" \
  -d '{"profile_key":null,"reason":"VERIFY_SCRIPT_RESET","issued_by":"verify-local.sh"}')
if [[ "$RESET_CODE" == "200" ]]; then
  ok "FORCE_EPISODE_RESET broadcast accepted (HTTP 200)"
else
  fail "FORCE_EPISODE_RESET broadcast failed (HTTP $RESET_CODE)"
fi

# 6. Component & Database State Report
step "6/7 Component Status, Prometheus Metrics & Postgres State"
docker compose ps
echo ""
info "Prometheus /metrics Output:"
curl -s --max-time 3 http://localhost:8080/metrics || true

echo ""
info "PostgreSQL Inventory & Strategy Pool Summary:"
docker compose exec -T postgres psql -U quant -d quantcore -c \
  "SELECT symbol, total_quantity, allocated_quantity, directional_bias, locked_by_agent FROM portfolio_inventory;"
docker compose exec -T postgres psql -U quant -d quantcore -c \
  "SELECT profile_key, replica_index, status, jitter_delta FROM strategy_pool ORDER BY profile_key, replica_index;"

# 7. Recent Service Logs
step "7/7 Recent Service Logs (migrations | nn-worker | quant-api)"
for SVC in migrations nn-worker quant-api; do
  echo -e "\n${YELLOW}--- Logs: $SVC (last 15 lines) ---${NC}"
  docker compose logs --tail=15 "$SVC"
done

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Verification Summary: ${GREEN}${PASS_COUNT} Passed${NC} | ${RED}${FAIL_COUNT} Failed${NC}"
echo -e "Live React Dashboard: ${CYAN}http://localhost:8080${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

[[ "$FAIL_COUNT" -eq 0 ]] || exit 1