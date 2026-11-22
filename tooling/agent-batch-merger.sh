#!/usr/bin/env bash
set -uo pipefail

# Automatically switch to the quant-core/ repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

OUT="agent-source-dump.txt"
rm -f "$OUT"

for f in \
  "src/QuantCore.Agents/Services/AgentSwarmHostedService.cs" \
  "src/QuantCore.Agents/Services/QuantApiClient.cs" \
  "src/QuantCore.Agents/Settlement/CarryPositionsStrategy.cs" \
  "src/QuantCore.Agents/Program.cs" \
  "docker-compose.yml"
do
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

echo "[OK] Dumped agent files to $(pwd)/$OUT ($(wc -l < "$OUT") lines)"