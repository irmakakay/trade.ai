#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

export REPO_ROOT
export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain
export COMPOSE_DOCKER_CLI_BUILD=1

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
  echo -e "${CYAN}Usage:${NC}"
  echo "  $0 local              # Switch agents to local SIMULATED gateway"
  echo "  $0 revolut [dry|live] # Switch to REVOLUT_X (defaults to safe DRY_RUN)"
  exit 1
}

TARGET_MODE="${1:-}"
SUB_MODE="${2:-dry}"

if [[ -z "$TARGET_MODE" ]]; then
  usage
fi

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

run_guarded() {
  local timeout_sec="$1"
  local label="$2"
  shift 2

  echo -e "${YELLOW}[INFO]${NC} Running: ${label} (timeout: ${timeout_sec}s)..."
  local log_file="/tmp/quant_gw_switch_$$.log"
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
      echo -e "${RED}[FAIL]${NC} TIMEOUT (${timeout_sec}s) during: ${label}"
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
    echo -e "${RED}[FAIL]${NC} ${label} failed (exit code ${exit_code})"
    tail -n 25 "$log_file" 2>/dev/null || true
    rm -f "$log_file"
    return "$exit_code"
  fi

  rm -f "$log_file"
  return 0
}

case "$(echo "$TARGET_MODE" | tr '[:upper:]' '[:lower:]')" in
  local|sim|simulated)
    GW_VAL="SIMULATED"
    DRY_VAL="true"
    LABEL="LOCAL (SIMULATED)"
    ;;
  revolut|revx|revolut_x)
    GW_VAL="REVOLUT_X"
    if [[ "$(echo "$SUB_MODE" | tr '[:upper:]' '[:lower:]')" == "live" ]]; then
      DRY_VAL="false"
      LABEL="REVOLUT_X (LIVE)"
    else
      DRY_VAL="true"
      LABEL="REVOLUT_X (DRY_RUN)"
    fi
    ;;
  *)
    usage
    ;;
esac

echo -e "${CYAN}━━━ [$(date +%H:%M:%S)] Switching Execution Gateway -> ${LABEL} ━━━${NC}"

if [[ -x "$REPO_ROOT/tooling/normalize-db.sh" ]]; then
  "$REPO_ROOT/tooling/normalize-db.sh"
fi

EXECUTION_GATEWAY="$GW_VAL" \
REVX_DRY_RUN="$DRY_VAL" \
REVX_MAX_ORDER_USDT="${REVX_MAX_ORDER_USDT:-25}" \
AGENT_PROFILE_KEY="ALL" \
EPISODE_SETTLEMENT_MODE="CARRY_POSITIONS" \
EPISODE_MAX_TICKS=25 \
  run_guarded 45 "Recreating 3 quant-agents with EXECUTION_GATEWAY=${GW_VAL} (DRY_RUN=${DRY_VAL})" \
  dc --profile agents up -d --scale quant-agents=3 --force-recreate quant-agents

echo -e "${GREEN}[OK]${NC} Gateway active: ${LABEL}"
echo -e "${YELLOW}[INFO]${NC} Streaming agent & nn-worker logs (Ctrl+C to stop):"
dc --profile agents logs -f --tail=20 quant-agents nn-worker