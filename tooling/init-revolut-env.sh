#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

SECRETS_DIR="$REPO_ROOT/.secrets/revx"
PRIV_KEY="$SECRETS_DIR/private.pem"
PUB_KEY="$SECRETS_DIR/public.pem"
ENV_FILE="$REPO_ROOT/.env"
REVX_URL="${REVX_WEB_URL:-https://revx.revolut.com}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}━━━ [$(date +%H:%M:%S)] Revolut X Ed25519 Keypair & .env Setup ━━━${NC}"

mkdir -p "$SECRETS_DIR"
chmod 700 "$REPO_ROOT/.secrets" "$SECRETS_DIR"

# Ensure .env and .secrets/ are gitignored
touch "$REPO_ROOT/.gitignore"
for entry in ".env" ".secrets/"; do
  if ! grep -qxF "$entry" "$REPO_ROOT/.gitignore"; then
    echo "$entry" >> "$REPO_ROOT/.gitignore"
  fi
done

if [[ ! -f "$PRIV_KEY" || ! -f "$PUB_KEY" ]]; then
  echo -e "${YELLOW}[INFO]${NC} Generating Ed25519 key pair..."
  openssl genpkey -algorithm ed25519 -out "$PRIV_KEY"
  openssl pkey -in "$PRIV_KEY" -pubout -out "$PUB_KEY"
  echo -e "${GREEN}[OK]${NC} Generated Ed25519 key pair in $SECRETS_DIR"
else
  echo -e "${GREEN}[OK]${NC} Reusing existing Ed25519 key pair in $SECRETS_DIR"
fi

chmod 600 "$PRIV_KEY"
chmod 644 "$PUB_KEY"

if command -v pbcopy >/dev/null 2>&1; then
  pbcopy < "$PUB_KEY"
  echo -e "${GREEN}[OK]${NC} Public key copied to macOS clipboard."
elif command -v xclip >/dev/null 2>&1; then
  xclip -selection clipboard < "$PUB_KEY" || true
fi

echo ""
echo -e "${CYAN}Public Key (paste this full block into Revolut X API Keys):${NC}"
cat "$PUB_KEY"
echo ""

if command -v open >/dev/null 2>&1; then
  open "$REVX_URL" >/dev/null 2>&1 || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$REVX_URL" >/dev/null 2>&1 || true
fi

echo -e "${YELLOW}[ACTION]${NC} In Revolut X (Profile -> API Keys), upload/paste the public key above and create your API key."
read -r -p "Paste your Revolut X API Key (leave blank to keep dry-run only): " API_KEY_INPUT
API_KEY_INPUT="$(echo "${API_KEY_INPUT:-}" | tr -d '[:space:]')"

# Read private key PEM content so it can be stored safely in .env or referenced by path
PRIV_PEM_SINGLE_LINE="$(awk 'NF {printf "%s\\n", $0}' "$PRIV_KEY")"

python3 - << PYEOF
from pathlib import Path

env_path = Path("$ENV_FILE")
existing = {}
if env_path.exists():
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            existing[k.strip()] = v

existing["REVX_API_BASE_URL"] = "https://revx.revolut.com"
existing["REVX_PRIVATE_KEY_PEM"] = f'"{ "$PRIV_PEM_SINGLE_LINE" }"'
existing["REVX_DRY_RUN"] = existing.get("REVX_DRY_RUN", "true")
existing["REVX_MAX_ORDER_USDT"] = existing.get("REVX_MAX_ORDER_USDT", "25")
if "$API_KEY_INPUT":
    existing["REVX_API_KEY"] = f'"{ "$API_KEY_INPUT" }"'
elif "REVX_API_KEY" not in existing:
    existing["REVX_API_KEY"] = '""'

lines = [f"{k}={v}" for k, v in existing.items()]
env_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PYEOF

chmod 600 "$ENV_FILE"
echo -e "${GREEN}[OK]${NC} Saved configuration to $ENV_FILE (permissions: 600, gitignored)."
echo -e "${YELLOW}[NEXT]${NC} Test in dry-run first with: ./tooling/switch-gateway.sh revolut dry"