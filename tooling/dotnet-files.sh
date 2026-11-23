#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

{
  for f in \
    src/QuantCore.Api/Services/BinanceMarketFeedHostedService.cs \
    src/QuantCore.Api/Endpoints/AgentEpisodeEndpoints.cs \
    src/quant_nn_engine/serialization/state_codec.py \
    src/QuantCore.Agents/Services/AgentSwarmHostedService.cs; do
    echo "===== $f ====="
    nl -ba "$f"
  done
} > four_files.txt && wc -l four_files.txt && grep '^=====' four_files.txt