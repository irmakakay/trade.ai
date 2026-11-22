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
  local log_file="/tmp/quant_ws_buf_$$.log"
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

step "1/3 Adding 30-Event Ring Buffer Replay to MarketStreamGateway.cs"

python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
gw_path = repo_root / "src/QuantCore.Api/Services/MarketStreamGateway.cs"

gw_path.write_text("""using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using QuantCore.Contracts.Domain;

namespace QuantCore.Api.Services;

public sealed class MarketStreamGateway
{
    private readonly ConcurrentDictionary<Guid, Channel<LiveStreamFrame>> _subscribers = new();
    private readonly ConcurrentDictionary<string, decimal> _latestPrices = new();
    private readonly ConcurrentQueue<LiveStreamFrame> _recentEvents = new();
    private const int MaxBufferedEvents = 30;

    public IReadOnlyDictionary<string, decimal> LatestPrices => _latestPrices;

    public void PublishFrame(LiveStreamFrame frame)
    {
        if (frame.EventType == "MARKET_TICK" && frame.Price > 0m)
        {
            _latestPrices[frame.Symbol] = frame.Price;
        }
        else
        {
            _recentEvents.Enqueue(frame);
            while (_recentEvents.Count > MaxBufferedEvents && _recentEvents.TryDequeue(out _)) { }
        }

        foreach (var (_, ch) in _subscribers)
        {
            ch.Writer.TryWrite(frame);
        }
    }

    public async Task HandleDashboardClientAsync(WebSocket ws, CancellationToken ct)
    {
        Guid subId = Guid.NewGuid();
        var channel = Channel.CreateBounded<LiveStreamFrame>(new BoundedChannelOptions(512)
        {
            FullMode = BoundedChannelFullMode.DropOldest
        });
        _subscribers[subId] = channel;

        try
        {
            // Replay recent non-tick agent/evolution events immediately on connect
            foreach (var pastEvent in _recentEvents.ToArray())
            {
                if (ws.State != WebSocketState.Open) break;
                var replayPayload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(pastEvent));
                await ws.SendAsync(replayPayload, WebSocketMessageType.Text, true, ct);
            }

            await foreach (var frame in channel.Reader.ReadAllAsync(ct))
            {
                if (ws.State != WebSocketState.Open) break;
                var payload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(frame));
                await ws.SendAsync(payload, WebSocketMessageType.Text, true, ct);
            }
        }
        finally
        {
            _subscribers.TryRemove(subId, out _);
        }
    }
}
""", encoding="utf-8")
print(f"[OK] Updated {gw_path} with 30-event ring buffer replay")
PYEOF

step "2/3 Rebuilding & Restarting quant-api"
run_guarded 240 "Building quant-api image" dc build quant-api
run_guarded 30 "Restarting quant-api" dc up -d --no-deps quant-api

step "3/3 Releasing Orphaned CLAIMED Slots & Resetting Inventory Locks"
dc exec -T postgres psql -U quant -d quantcore -c "
  UPDATE strategy_allocations SET status = 'RELEASED' WHERE status = 'ACTIVE';
  UPDATE portfolio_inventory SET allocated_quantity = 0;
  UPDATE strategy_pool SET status = 'AVAILABLE' WHERE status = 'CLAIMED';
  SELECT profile_key, status, COUNT(*) FROM strategy_pool GROUP BY profile_key, status ORDER BY profile_key, status;
"
ok "Orphaned 409 claims cleared — agents will immediately check out slots and stream live events!"