#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

SECRETS_DIR="$REPO_ROOT/.secrets/revx"
PRIV_KEY="$SECRETS_DIR/private.pem"
PUB_KEY="$SECRETS_DIR/public.pem"
ENV_FILE="$REPO_ROOT/.env"

mkdir -p "$SECRETS_DIR"
chmod 700 "$REPO_ROOT/.secrets" "$SECRETS_DIR"

touch "$REPO_ROOT/.gitignore"
for entry in ".env" ".secrets/"; do
  if ! grep -qxF "$entry" "$REPO_ROOT/.gitignore"; then
    echo "$entry" >> "$REPO_ROOT/.gitignore"
  fi
done

if [[ ! -f "$PRIV_KEY" || ! -f "$PUB_KEY" ]]; then
  openssl genpkey -algorithm ed25519 -out "$PRIV_KEY"
  openssl pkey -in "$PRIV_KEY" -pubout -out "$PUB_KEY"
fi

chmod 600 "$PRIV_KEY"
chmod 644 "$PUB_KEY"

PRIV_PEM_ESCAPED="$(awk 'NF {printf "%s\\n", $0}' "$PRIV_KEY")"

python3 - << PYEOF
from pathlib import Path

env_path = Path("$ENV_FILE")
data = {}
if env_path.exists():
    for line in env_path.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            data[k.strip()] = v

data.setdefault("REVX_API_KEY", '""')
data["REVX_API_BASE_URL"] = data.get("REVX_API_BASE_URL", "https://revx.revolut.com")
data["REVX_PRIVATE_KEY_PEM"] = f'"{ "$PRIV_PEM_ESCAPED" }"'
data["REVX_DRY_RUN"] = data.get("REVX_DRY_RUN", "true")
data["REVX_MAX_ORDER_USDT"] = data.get("REVX_MAX_ORDER_USDT", "25")

env_path.write_text("\n".join(f"{k}={v}" for k, v in data.items()) + "\n", encoding="utf-8")
PYEOF

chmod 600 "$ENV_FILE"

echo "[OK] Keypair ready in $SECRETS_DIR and .env updated (REVX_DRY_RUN=true)."
echo "[OK] Public key to register in Revolut X:"
cat "$PUB_KEY"