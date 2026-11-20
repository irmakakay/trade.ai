#!/usr/bin/env bash
set -uo pipefail

# Automatically switch to the quant-core/ repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain
export COMPOSE_DOCKER_CLI_BUILD=1

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step() { echo -e "\n${CYAN}━━━ [$(date +%H:%M:%S)] $1 ━━━${NC}"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

run_guarded() {
  local timeout_sec="$1"
  local label="$2"
  shift 2

  info "Running: ${label} (timeout: ${timeout_sec}s)..."
  local log_file="/tmp/quant_fix_$$.log"
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

step "1/4 Patching AgentEpisodeEndpoints.cs & LiveDashboard.tsx"

python3 - << 'PYEOF'
from pathlib import Path

ep_path = Path("src/QuantCore.Api/Endpoints/AgentEpisodeEndpoints.cs")
code = ep_path.read_text(encoding="utf-8")

code = code.replace(
    "if (req.LiquidateAndReleaseSlices)\n            {",
    "// Always release DB slice reservation at episode boundary so next generation is never starved\n            {"
)

if "total_checkpoints" not in code:
    code = code.replace(
        "COALESCE(MAX(max_drawdown_pct), 0) AS worst_drawdown_pct\n                FROM trading_history;",
        """COALESCE(MAX(max_drawdown_pct), 0) AS worst_drawdown_pct,
                    (SELECT COUNT(1) FROM nn_model_checkpoints) AS total_checkpoints
                FROM trading_history;"""
    )

ep_path.write_text(code, encoding="utf-8")
print("[OK] Updated src/QuantCore.Api/Endpoints/AgentEpisodeEndpoints.cs")

ui_path = Path("src/quant-ui/src/components/LiveDashboard.tsx")
ui_code = ui_path.read_text(encoding="utf-8")

if "total_checkpoints?" not in ui_code:
    ui_code = ui_code.replace(
        "worst_drawdown_pct: number;\n  };",
        "worst_drawdown_pct: number;\n    total_checkpoints?: number;\n  };"
    )

ui_code = ui_code.replace(
    "{summary?.nn_checkpoints?.length ?? 0} Checkpoints",
    "{kpis?.total_checkpoints ?? summary?.nn_checkpoints?.length ?? 0} Checkpoints"
)

ui_path.write_text(ui_code, encoding="utf-8")
print("[OK] Updated src/quant-ui/src/components/LiveDashboard.tsx")
PYEOF

step "2/4 Rebuilding & Restarting quant-api"
run_guarded 240 "Building quant-api image" docker compose build quant-api
run_guarded 30 "Restarting quant-api" docker compose up -d --no-deps quant-api

step "3/4 Releasing Exhausted Portfolio Inventory & Resetting Stuck Claims"
docker compose exec -T postgres psql -U quant -d quantcore -c "
  UPDATE strategy_allocations SET status = 'RELEASED' WHERE status = 'ACTIVE';
  UPDATE portfolio_inventory SET allocated_quantity = 0;
  UPDATE strategy_pool SET status = 'AVAILABLE' WHERE status = 'CLAIMED';
"
ok "Portfolio inventory unallocated and pool slots ready for Generation 2+"

step "4/4 Restarting 3x quant-agents & Streaming [NN-EVOLUTION] Progress"
AGENT_PROFILE_KEY="AGGRESSIVE_BREAKOUT" \
EPISODE_SETTLEMENT_MODE="CARRY_POSITIONS" \
EPISODE_MAX_TICKS=20 \
  run_guarded 45 "Restarting 3 quant-agents replicas" \
  docker compose --profile agents up -d --scale quant-agents=3 --force-recreate quant-agents

ok "Swarm restarted! Streaming live NN Evolution logs (Press Ctrl+C to exit log view):"
docker compose --profile agents logs -f --tail=20 nn-worker quant-agents