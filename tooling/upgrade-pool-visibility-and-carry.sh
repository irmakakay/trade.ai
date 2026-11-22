#!/usr/bin/env bash
set -uo pipefail

# Resolve absolute path to quant-core/ repository root regardless of current working directory
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

step() { echo -e "\n${CYAN}━━━ [$(date +%H:%M:%S)] $1 ━━━${NC}"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

run_guarded() {
  local timeout_sec="$1"
  local label="$2"
  shift 2

  info "Running: ${label} (timeout: ${timeout_sec}s)..."
  local log_file="/tmp/quant_vis_$$.log"
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

step "1/4 Patching API Summary, UI Strategy Pool Telemetry & Per-Profile NN Promotion Gate"

python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()

# 1. Expose strategy_payload in AgentEpisodeEndpoints.cs poolStateSql
ep_path = repo_root / "src/QuantCore.Api/Endpoints/AgentEpisodeEndpoints.cs"
ep_code = ep_path.read_text(encoding="utf-8")
ep_code = ep_code.replace(
    """            const string poolStateSql = @"
                SELECT profile_key, replica_index, status, risk_dial_r
                FROM strategy_pool
                WHERE status IN ('AVAILABLE', 'CLAIMED')
                ORDER BY profile_key, replica_index;";""",
    """            const string poolStateSql = @"
                SELECT profile_key, replica_index, status, risk_dial_r, strategy_payload::text AS strategy_payload
                FROM strategy_pool
                WHERE status IN ('AVAILABLE', 'CLAIMED')
                ORDER BY profile_key, replica_index;";"""
)
ep_path.write_text(ep_code, encoding="utf-8")
print(f"[OK] Updated {ep_path}")

# 2. Update bridge.py to track per-profile generation counts & require positive Sharpe for PROMOTED
bridge_path = repo_root / "src/quant_nn_engine/bridge.py"
bridge_code = bridge_path.read_text(encoding="utf-8")

if "self.generation_by_profile" not in bridge_code:
    bridge_code = bridge_code.replace(
        "self.generation_count: int = 0",
        "self.generation_count: int = 0\n        self.generation_by_profile: Dict[str, int] = {}"
    )

bridge_code = bridge_code.replace(
    "def train_on_generation_histories(\n        self,\n        histories: List[ReplicaHistoryRecord],\n        risk_dial_r: float,\n        epochs: int = 6,\n    ) -> float:",
    "def train_on_generation_histories(\n        self,\n        histories: List[ReplicaHistoryRecord],\n        risk_dial_r: float,\n        profile_key: str = \"DEFAULT\",\n        epochs: int = 6,\n    ) -> float:"
)

bridge_code = bridge_code.replace(
    "self.generation_count += 1",
    "self.generation_count += 1\n        gen_num = self.generation_by_profile.get(profile_key, 0) + 1\n        self.generation_by_profile[profile_key] = gen_num"
)

bridge_code = bridge_code.replace(
    "maturity_bonus = min(0.32, self.generation_count * 0.065)",
    "maturity_bonus = min(0.28, gen_num * 0.055)"
)

bridge_code = bridge_code.replace(
    "train_loss = self.train_on_generation_histories(prior_histories, risk_dial_r)",
    "train_loss = self.train_on_generation_histories(prior_histories, risk_dial_r, profile_key=profile_key)"
)

bridge_code = bridge_code.replace(
    "is_promoted_for_live=confidence >= self.confidence_threshold,",
    "is_promoted_for_live=(confidence >= self.confidence_threshold and (not prior_histories or max(h.sharpe_estimate for h in prior_histories) > 0.0)),"
)

bridge_code = bridge_code.replace(
    '"generation": self.generation_count,',
    '"generation": self.generation_by_profile.get(profile_key, self.generation_count),'
)

bridge_path.write_text(bridge_code, encoding="utf-8")
print(f"[OK] Updated {bridge_path}")

# 3. Update LiveDashboard.tsx to pin Active Strategy Pool & display live evolved SL / TP per slot
ui_path = repo_root / "src/quant-ui/src/components/LiveDashboard.tsx"
ui_code = ui_path.read_text(encoding="utf-8")

ui_code = ui_code.replace(
    """  pool_state: Array<{
    profile_key: string;
    replica_index: number;
    status: string;
    risk_dial_r: number;
  }>;""",
    """  pool_state: Array<{
    profile_key: string;
    replica_index: number;
    status: string;
    risk_dial_r: number;
    strategy_payload?: string;
  }>;"""
)

old_right_panel = """        <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: "10px", padding: "14px" }}>
          <h3 style={{ margin: "0 0 10px 0", fontSize: "14px", color: "#e2e8f0" }}>PyTorch NN Checkpoints & Strategy Pool Status</h3>
          <div style={{ maxHeight: "200px", overflowY: "auto", fontSize: "12px", fontFamily: "ui-monospace, monospace" }}>
            {(summary?.nn_checkpoints ?? []).map((cp, i) => (
              <div key={i} style={{ padding: "6px 0", borderBottom: "1px solid #1e293b", display: "flex", justifyContent: "space-between" }}>
                <span style={{ color: "#c084fc", fontWeight: 600 }}>{cp.version_tag}</span>
                <span style={{ color: "#e2e8f0" }}>Conf: {(Number(cp.confidence_score) * 100).toFixed(1)}%</span>
                <span style={{ color: cp.is_promoted_live ? "#4ade80" : "#facc15" }}>
                  {cp.is_promoted_live ? "PROMOTED" : "SHADOW"}
                </span>
              </div>
            ))}
            <div style={{ marginTop: "10px", paddingTop: "6px", borderTop: "1px solid #334155", color: "#94a3b8" }}>
              Active Pool Slots: {(summary?.pool_state ?? []).map((s) => `${s.profile_key.slice(0, 4)}#${s.replica_index}:${s.status}`).join(" | ")}
            </div>
          </div>
        </div>"""

new_right_panel = """        <div style={{ background: "#0f172a", border: "1px solid #1e293b", borderRadius: "10px", padding: "14px", display: "flex", flexDirection: "column", justifyContent: "space-between" }}>
          <div>
            <h3 style={{ margin: "0 0 8px 0", fontSize: "14px", color: "#e2e8f0" }}>PyTorch NN Checkpoints & Strategy Pool Status</h3>
            <div style={{ maxHeight: "125px", overflowY: "auto", fontSize: "12px", fontFamily: "ui-monospace, monospace" }}>
              {(summary?.nn_checkpoints ?? []).map((cp, i) => (
                <div key={i} style={{ padding: "4px 0", borderBottom: "1px solid #1e293b", display: "flex", justifyContent: "space-between" }}>
                  <span style={{ color: "#c084fc", fontWeight: 600 }}>{cp.version_tag}</span>
                  <span style={{ color: "#e2e8f0" }}>Conf: {(Number(cp.confidence_score) * 100).toFixed(1)}%</span>
                  <span style={{ color: cp.is_promoted_live ? "#4ade80" : "#facc15", fontWeight: 700 }}>
                    {cp.is_promoted_live ? "PROMOTED" : "SHADOW"}
                  </span>
                </div>
              ))}
            </div>
          </div>
          <div style={{ marginTop: "8px", paddingTop: "8px", borderTop: "1px solid #334155", fontSize: "11px", fontFamily: "ui-monospace, monospace" }}>
            <div style={{ color: "#94a3b8", fontWeight: 700, marginBottom: "4px" }}>LIVE EVOLVED STRATEGY POOL (SL / TP / SLICE):</div>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: "4px" }}>
              {(summary?.pool_state ?? []).map((s, idx) => {
                let meta = "";
                try {
                  if (s.strategy_payload) {
                    const p = JSON.parse(s.strategy_payload);
                    meta = `SL:${Number(p.stop_loss_atr).toFixed(2)} TP:${Number(p.take_profit_rr).toFixed(2)}`;
                  }
                } catch {}
                const isClaimed = s.status === "CLAIMED";
                return (
                  <div key={idx} style={{ background: "#060911", padding: "4px 6px", borderRadius: "4px", border: isClaimed ? "1px solid #38bdf8" : "1px solid #1e293b" }}>
                    <div style={{ color: isClaimed ? "#38bdf8" : "#cbd5e1", fontWeight: 700 }}>
                      {s.profile_key.slice(0, 4)}#{s.replica_index} <span style={{ color: isClaimed ? "#4ade80" : "#64748b" }}>{isClaimed ? "RUN" : "RDY"}</span>
                    </div>
                    <div style={{ color: "#94a3b8", fontSize: "10px" }}>{meta || `r=${s.risk_dial_r}`}</div>
                  </div>
                );
              })}
            </div>
          </div>
        </div>"""

if old_right_panel in ui_code:
    ui_code = ui_code.replace(old_right_panel, new_right_panel)
    print(f"[OK] Updated {ui_path} with pinned 3x3 Live Evolved Strategy Pool grid")
else:
    print(f"[WARN] Could not match old_right_panel block in {ui_path}")

ui_path.write_text(ui_code, encoding="utf-8")
PYEOF

step "2/4 Rebuilding & Restarting nn-worker and quant-api"
run_guarded 240 "Building nn-worker image" dc build nn-worker
run_guarded 240 "Building quant-api image" dc build quant-api
run_guarded 30 "Restarting nn-worker and quant-api" dc up -d --no-deps nn-worker quant-api

step "3/4 Resetting Active Inventory Locks & Stale Claims"
dc exec -T postgres psql -U quant -d quantcore -c "
  UPDATE strategy_allocations SET status = 'RELEASED' WHERE status = 'ACTIVE';
  UPDATE portfolio_inventory SET allocated_quantity = 0;
  UPDATE strategy_pool SET status = 'AVAILABLE' WHERE status = 'CLAIMED';
"
ok "Database locks cleared"

step "4/4 Force-Recreating 3x Multiplexed Agents in CARRY_POSITIONS Mode"
AGENT_PROFILE_KEY="ALL" \
EPISODE_SETTLEMENT_MODE="CARRY_POSITIONS" \
EPISODE_MAX_TICKS=25 \
  run_guarded 45 "Force-recreating 3 quant-agents in CARRY_POSITIONS mode" \
  dc --profile agents up -d --scale quant-agents=3 --force-recreate quant-agents

ok "Swarm active in CARRY_POSITIONS mode! Hard-refresh http://localhost:8080 (Cmd+Shift+R) to see the live 3x3 Strategy Pool SL/TP grid and CARRIED commits."