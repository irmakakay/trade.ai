#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

OUT="$REPO_ROOT/nn-and-feed-dump.txt"
rm -f "$OUT"

for f in \
  "src/quant_nn_worker/main.py" \
  "src/quant_nn_engine/bridge.py" \
  "src/quant_nn_engine/codec.py" \
  "src/quant_nn_engine/model.py" \
  "src/QuantCore.Api/Services/BinanceMarketFeedHostedService.cs" \
  "src/QuantCore.Api/Endpoints/AgentEpisodeEndpoints.cs"
do
  echo "=================================================================" >> "$OUT"
  echo "FILE: $f" >> "$OUT"
  echo "=================================================================" >> "$OUT"
  if [[ -f "$REPO_ROOT/$f" ]]; then
    cat "$REPO_ROOT/$f" >> "$OUT"
  else
    echo "[MISSING]: $f" >> "$OUT"
  fi
  echo -e "\n" >> "$OUT"
done

echo "[OK] Dumped NN & Market Feed files to $OUT ($(wc -l < "$OUT") lines)"