#!/usr/bin/env bash
set -uo pipefail

export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain
export COMPOSE_DOCKER_CLI_BUILD=1

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

 PROFILE_KEY="${AGENT_PROFILE_KEY:-AGGRESSIVE_BREAKOUT}"
MAX_TICKS="${EPISODE_MAX_TICKS:-20}"
REPLICAS="${POOL_REPLICATION_FACTOR:-3}"
SETTLEMENT_MODE="${EPISODE_SETTLEMENT_MODE:-LIQUIDATE_AND_RELEASE}"

step() { echo -e "\n${CYAN}━━━ [$(date +%H:%M:%S)] $1 ━━━${NC}"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

run_guarded() {
  local timeout_sec="$1"
  local label="$2"
  shift 2

  info "Running: ${label} (timeout: ${timeout_sec}s)..."
  local log_file="/tmp/quant_agents_$$.log"
  rm -f "$log_file"

  "$@" >"$log_file" 2>&1 &
  local cmd_pid=$!
  local elapsed=0

  while kill -0 "$cmd_pid" 2>/dev/null; do
    local last_line=""
    if [[ -s "$log_file" ]]; then
      last_line=$(tail -n 1 "$log_file" | tr -d '\r' | cut -c1-70)
    fi
    printf "\r  ⏳ [%3ds / %3ds] %s -> %-70s" "$elapsed" "$timeout_sec" "$label" "${last_line:-working...}"
    sleep 1
    elapsed=$((elapsed + 1))

    if [[ "$elapsed" -ge "$timeout_sec" ]]; then
      echo ""
      fail "TIMEOUT (${timeout_sec}s) during: ${label}"
      kill -9 "$cmd_pid" 2>/dev/null || true
      tail -n 20 "$log_file" 2>/dev/null || true
      rm -f "$log_file"
      return 1
    fi
  done

  wait "$cmd_pid"
  local exit_code=$?
  printf "\r\033[K"

  if [[ "$exit_code" -ne 0 ]]; then
    fail "${label} failed (exit code ${exit_code})"
    tail -n 25 "$log_file" 2>/dev/null || true
    rm -f "$log_file"
    return "$exit_code"
  fi

  rm -f "$log_file"
  return 0
}

if [[ ! -f "docker-compose.yml" ]]; then
  fail "Run this script from inside the quant-core/ root directory."
  exit 1
fi

# 1. Ensure Core Stack (Postgres, RabbitMQ, NN-Worker, Quant-API) is Up
step "1/5 Verifying Core Infrastructure & Rebuilding UI/API if Needed"
if [[ "${REBUILD_API:-0}" == "1" ]]; then
  run_guarded 240 "Rebuilding quant-api (no-cache)" docker compose build --no-cache quant-api
  run_guarded 30 "Restarting quant-api" docker compose up -d quant-api
else
  run_guarded 45 "Ensuring core services are running" docker compose up -d postgres rabbitmq nn-worker quant-api
fi
ok "Core stack is active"

# 2. Reset Stale Strategy Pool Slots & Unreleased Slices
step "2/5 Resetting Stale Strategy Pool Slots & Inventory Locks in PostgreSQL"
docker compose exec -T postgres psql -U quant -d quantcore -c "
  UPDATE strategy_pool
  SET status = 'AVAILABLE', claimed_by_agent = NULL, claimed_at = NULL
  WHERE status != 'AVAILABLE';

  UPDATE strategy_allocations
  SET status = 'RELEASED'
  WHERE status = 'ACTIVE';

  UPDATE portfolio_inventory
  SET allocated_quantity = 0, locked_by_agent = NULL, lock_expires_at = NULL;
"
ok "All strategy_pool slots reset to AVAILABLE and inventory locks cleared"

# 3. Build & Scale the K-Replica Agent Swarm
step "3/5 Building & Launching ${REPLICAS}x quant-agents (Profile: ${PROFILE_KEY} | MaxTicks: ${MAX_TICKS})"
run_guarded 180 "Building quant-agents image" docker compose --profile agents build quant-agents

AGENT_PROFILE_KEY="$PROFILE_KEY" \
EPISODE_MAX_TICKS="$MAX_TICKS" \
EPISODE_SETTLEMENT_MODE="$SETTLEMENT_MODE" \
  run_guarded 45 "Starting ${REPLICAS} quant-agents replicas" \
  docker compose --profile agents up -d --scale quant-agents="$REPLICAS" quant-agents

ok "Agent swarm (${REPLICAS} replicas) is running"

# 4. Wait 5 Seconds & Print Initial Execution / Database Snapshot
step "4/5 Polling Initial Agent Checkouts & Database Snapshot"
for i in {1..5}; do
  printf "\r  ⏳ Letting agents claim slots and process initial ticks... (%ds/5s)" "$i"
  sleep 1
done
echo ""

docker compose --profile agents ps
echo ""
info "Active Strategy Pool State:"
docker compose exec -T postgres psql -U quant -d quantcore -c \
  "SELECT profile_key, replica_index, status, claimed_by_agent FROM strategy_pool ORDER BY profile_key, replica_index;"

info "Recent Completed Episodes (trading_history):"
docker compose exec -T postgres psql -U quant -d quantcore -c \
  "SELECT profile_key, replica_index, realized_pnl_usdt, sharpe_estimate, max_drawdown_pct, completed_at FROM trading_history ORDER BY completed_at DESC LIMIT 5;"

info "PyTorch NN Checkpoints (nn_model_checkpoints):"
docker compose exec -T postgres psql -U quant -d quantcore -c \
  "SELECT version_tag, confidence_score, is_promoted_live, created_at FROM nn_model_checkpoints ORDER BY created_at DESC LIMIT 5;"

# 5. Stream Live Logs (Ctrl+C to stop viewing logs without stopping containers)
step "5/5 Streaming Live Swarm & NN Evolution Logs (Press Ctrl+C to exit log view)"
info "Dashboard URL: http://localhost:8080 (Press Cmd+Shift+R in browser if UI was rebuilt)"
docker compose --profile agents logs -f --tail=20 quant-agents nn-worker quant-api