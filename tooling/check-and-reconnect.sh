#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "=== 1. CONTAINER STATUS ==="
docker compose --profile agents ps

echo "=== 2. RECENT AGENT & API LOGS ==="
docker compose --profile agents logs --tail=15 quant-agents quant-api

echo "=== 3. ENSURING 3 MULTIPLEXED AGENTS ARE RUNNING ==="
AGENT_PROFILE_KEY="ALL" \
EPISODE_SETTLEMENT_MODE="CARRY_POSITIONS" \
EPISODE_MAX_TICKS=25 \
  docker compose --profile agents up -d --scale quant-agents=3 quant-agents
