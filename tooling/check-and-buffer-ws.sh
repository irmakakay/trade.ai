#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

export REPO_ROOT
export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain
export COMPOSE_DOCKER_CLI_BUILD=1

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

echo "=== 1. LIVE AGENT & NN-WORKER LOG TAIL ==="
dc --profile agents logs --tail=20 quant-agents nn-worker

echo ""
echo "=== 2. CHECKING MarketStreamGateway.cs FOR RING BUFFER REPLAY ==="
GATEWAY_FILE="$REPO_ROOT/src/QuantCore.Api/Services/MarketStreamGateway.cs"
if [[ -f "$GATEWAY_FILE" ]]; then
  cat "$GATEWAY_FILE"
else
  echo "[WARN] $GATEWAY_FILE not found"
fi