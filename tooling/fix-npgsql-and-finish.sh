#!/usr/bin/env bash
set -euo pipefail

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

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

echo -e "${CYAN}━━━ [$(date +%H:%M:%S)] Adding Npgsql PackageReference to QuantCore.Agents.csproj ━━━${NC}"

python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
csproj_path = repo_root / "src/QuantCore.Agents/QuantCore.Agents.csproj"
csproj_code = csproj_path.read_text(encoding="utf-8")

if "Npgsql" not in csproj_code:
    pkg_ref = '    <PackageReference Include="Npgsql" Version="8.0.5" />\n'
    if "</ItemGroup>" in csproj_code:
        csproj_code = csproj_code.replace("</ItemGroup>", pkg_ref + "  </ItemGroup>", 1)
    else:
        csproj_code = csproj_code.replace(
            "</Project>",
            f"  <ItemGroup>\n{pkg_ref}  </ItemGroup>\n</Project>",
        )
    csproj_path.write_text(csproj_code, encoding="utf-8")
    print(f"[OK] Added Npgsql 8.0.5 to {csproj_path}")
else:
    print(f"[OK] Npgsql already present in {csproj_path}")
PYEOF

echo -e "${CYAN}━━━ [$(date +%H:%M:%S)] Running .NET Build & Tests ━━━${NC}"
dotnet test "$REPO_ROOT/tests/QuantCore.Agents.Tests/QuantCore.Agents.Tests.csproj" -c Release --nologo -v minimal
echo -e "${GREEN}[OK]${NC} QuantCore.Agents compiled and baseline tests passed"

echo -e "${CYAN}━━━ [$(date +%H:%M:%S)] Rebuilding & Refreshing Docker Services ━━━${NC}"
if [[ -x "$REPO_ROOT/tooling/refresh-dockers.sh" ]]; then
  "$REPO_ROOT/tooling/refresh-dockers.sh"
else
  dc build nn-worker
  dc --profile agents build quant-agents
  dc --profile agents up -d --scale quant-agents=3 --force-recreate quant-agents nn-worker
fi