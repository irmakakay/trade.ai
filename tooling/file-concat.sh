#!/usr/bin/env bash
set -uo pipefail

OUT="nn-source-dump.txt"
rm -f "$OUT"

FILES=(
  "/Users/irmcdaddy/workspace/trade.ai/quant-core/src/quant_nn_engine/bridge.py"
  "/Users/irmcdaddy/workspace/trade.ai/quant-core/src/quant_nn_engine/contracts.py"
  "/Users/irmcdaddy/workspace/trade.ai/quant-core/src/quant_nn_engine/models/network.py"
  "/Users/irmcdaddy/workspace/trade.ai/quant-core/src/quant_nn_engine/models/loss.py"
  "/Users/irmcdaddy/workspace/trade.ai/quant-core/src/quant_nn_engine/evolution/empirical_gradient.py"
  "/Users/irmcdaddy/workspace/trade.ai/quant-core/src/quant_nn_worker/main.py"
  "/Users/irmcdaddy/workspace/trade.ai/quant-core/src/QuantCore.Api/Endpoints/AgentEpisodeEndpoints.cs"
)

for f in "${FILES[@]}"; do
  echo "=================================================================" >> "$OUT"
  echo "FILE: $f" >> "$OUT"
  echo "=================================================================" >> "$OUT"
  if [[ -f "$f" ]]; then
    cat "$f" >> "$OUT"
  else
    echo "[MISSING]: $f" >> "$OUT"
  fi
  echo -e "\n" >> "$OUT"
done

echo "[OK] Dumped ${#FILES[@]} files to $OUT ($(wc -l < "$OUT") lines)"