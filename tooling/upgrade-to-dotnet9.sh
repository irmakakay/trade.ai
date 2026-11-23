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
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}━━━ [$(date +%H:%M:%S)] Upgrading .NET Projects & Dockerfiles to net9.0 ━━━${NC}"

python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()

# 1. Update all .csproj files under src/ and tests/
for base_dir in ("src", "tests"):
    root = repo_root / base_dir
    if not root.exists():
        continue
    for csproj in root.rglob("*.csproj"):
        text = csproj.read_text(encoding="utf-8")
        updated = text.replace("<TargetFramework>net8.0</TargetFramework>", "<TargetFramework>net9.0</TargetFramework>")
        updated = updated.replace("<TargetFrameworks>net8.0", "<TargetFrameworks>net9.0")
        updated = updated.replace('PackageReference Include="Npgsql" Version="8.0.5"', 'PackageReference Include="Npgsql" Version="9.0.2"')
        if updated != text:
            csproj.write_text(updated, encoding="utf-8")
            print(f"[OK] Updated {csproj}")

# 2. Update dotnet 8.0 base images in Dockerfiles
for df in repo_root.rglob("Dockerfile*"):
    if any(part in df.parts for part in (".git", "node_modules", "bin", "obj")):
        continue
    text = df.read_text(encoding="utf-8")
    updated = text
    for old_tag, new_tag in [
        (":8.0-alpine", ":9.0-alpine"),
        (":8.0-jammy", ":9.0-jammy"),
        (":8.0-noble", ":9.0-noble"),
        (":8.0", ":9.0"),
    ]:
        updated = updated.replace(old_tag, new_tag)
    if updated != text:
        df.write_text(updated, encoding="utf-8")
        print(f"[OK] Updated {df}")
PYEOF

echo -e "${CYAN}━━━ [$(date +%H:%M:%S)] Running dotnet test on net9.0 ━━━${NC}"
dotnet test "$REPO_ROOT/tests/QuantCore.Agents.Tests/QuantCore.Agents.Tests.csproj" -c Release --nologo -v minimal
echo -e "${GREEN}[OK]${NC} All .NET 9 tests passed"

echo -e "${CYAN}━━━ [$(date +%H:%M:%S)] Rebuilding & Refreshing Docker Services ━━━${NC}"
if [[ -x "$REPO_ROOT/tooling/refresh-dockers.sh" ]]; then
  "$REPO_ROOT/tooling/refresh-dockers.sh"
else
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" build nn-worker
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" --profile agents build quant-agents
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" --profile agents up -d --scale quant-agents=3 --force-recreate quant-agents nn-worker
fi