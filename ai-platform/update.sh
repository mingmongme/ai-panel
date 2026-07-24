#!/usr/bin/env bash
# AI for You — quick update (VPS side)
# Re-downloads the latest tarball, keeps existing data/app.env, appends any
# newly-introduced config keys (blank) to app.env, then refuses to restart
# the service if a required key is still blank.
#
# Usage (on the VPS):
#   curl -fsSL https://raw.githubusercontent.com/mingmongme/ai-panel/main/ai-platform/update.sh -o /tmp/update.sh
#   sudo bash /tmp/update.sh
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/ai-platform}"
TARBALL_URL="https://raw.githubusercontent.com/mingmongme/ai-panel/main/ai-platform/ai-for-you-v1.tar.gz"
REQUIRED_KEYS_URL="https://raw.githubusercontent.com/mingmongme/ai-panel/main/ai-platform/required-env-keys.txt"
EXAMPLE_KEYS_URL="https://raw.githubusercontent.com/mingmongme/ai-panel/main/ai-platform/.env.example"

RED='\033[31m'; GREEN='\033[32m'; BLUE='\033[34m'; BOLD='\033[1m'; RESET='\033[0m'
status() { printf "${BLUE}==>${RESET} ${BOLD}%s${RESET}\n" "$1"; }
ok()     { printf "${GREEN}\u2714${RESET} %s\n" "$1"; }
die()    { printf "${RED}Error:${RESET} %s\n" "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo bash update.sh)"
[ -d "$DEPLOY_DIR/app" ] || die "$DEPLOY_DIR/app not found — run install.sh first"
[ -f "$DEPLOY_DIR/app.env" ] || die "$DEPLOY_DIR/app.env not found — run install.sh first"

# Fails loudly if any key listed in required-env-keys.txt is missing or blank
# in the given env file. Kept identical to install.sh's copy on purpose.
validate_required_env() {
  local env_file="$1"
  local keys_file="$2"
  [ -s "$keys_file" ] || die "Could not load the required-config checklist ($keys_file is missing or empty) — refusing to restart with unverified config."
  local missing=()
  while IFS= read -r key || [ -n "$key" ]; do
    key="$(echo "$key" | sed 's/#.*//' | xargs)"
    [ -z "$key" ] && continue
    local value
    value="$(grep -E "^${key}=" "$env_file" | tail -n1 | cut -d'=' -f2- | xargs)"
    if [ -z "$value" ]; then
      missing+=("$key")
    fi
  done < "$keys_file"
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "" >&2
    printf "${RED}Error:${RESET} the following required config values are missing or blank in %s:\n" "$env_file" >&2
    for k in "${missing[@]}"; do printf "  - %s\n" "$k" >&2; done
    echo "Set a real value for each key above, then re-run this script (the service was NOT restarted)." >&2
    exit 1
  fi
}

status "Step 1/5 — Backing up config"
cp "$DEPLOY_DIR/app.env" "$DEPLOY_DIR/app.env.bak.$(date +%s)"
ok "Backed up app.env"

status "Step 2/5 — Downloading latest app"
curl -fsSL "$TARBALL_URL" -o /tmp/ai-for-you.tar.gz || die "Could not download app from GitHub"
rm -rf "$DEPLOY_DIR/app"
mkdir -p "$DEPLOY_DIR/app"
tar -xzf /tmp/ai-for-you.tar.gz -C "$DEPLOY_DIR/app"
rm -f /tmp/ai-for-you.tar.gz
cd "$DEPLOY_DIR/app"
npm install --omit=dev --no-audit --no-fund
ok "App updated in $DEPLOY_DIR/app"

status "Step 3/5 — Syncing new config keys"
curl -fsSL "$EXAMPLE_KEYS_URL" -o /tmp/.env.example 2>/dev/null || true
if [ -s /tmp/.env.example ]; then
  added=0
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip blank lines and comment-only lines before any shell word-splitting
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Lines without '=' are not key=value lines
    [[ "$line" != *"="* ]] && continue
    key="${line%%=*}"
    key="${key// /}"   # strip spaces without xargs (avoids quote parsing issues)
    [ -z "$key" ] && continue
    case "$key" in \#*) continue ;; esac
    grep -q "^${key}=" "$DEPLOY_DIR/app.env" || { echo "${key}=" >> "$DEPLOY_DIR/app.env"; added=$((added + 1)); }
  done < /tmp/.env.example
  rm -f /tmp/.env.example
  ok "Synced config keys (${added} new key(s) appended, review before restart if any)"
else
  echo "  (no .env.example published yet, skipping key sync)"
fi

status "Step 4/5 — Validating required config"
curl -fsSL "$REQUIRED_KEYS_URL" -o "$DEPLOY_DIR/required-env-keys.txt" || die "Could not download required-env-keys.txt from GitHub — cannot verify config, aborting before restarting the service."
validate_required_env "$DEPLOY_DIR/app.env" "$DEPLOY_DIR/required-env-keys.txt"
ok "Required config values present"

status "Step 5/5 — Restarting service"
# Self-heal: if the service file still points to the old server/ path, fix it now
SERVICE_FILE="/etc/systemd/system/ai-panel.service"
if [ -f "$SERVICE_FILE" ] && grep -q "node server/index.mjs" "$SERVICE_FILE"; then
  sed -i 's|node server/index.mjs|node dist/index.mjs|' "$SERVICE_FILE"
  ok "Fixed service ExecStart path (server/ → dist/)"
fi
# Always reload the unit to pick up any on-disk changes before restarting
systemctl daemon-reload
systemctl restart ai-panel
sleep 2
if curl -fsS http://127.0.0.1:8080/ >/dev/null 2>&1; then
  ok "App responding on port 8080"
else
  echo -e "${RED}App did not respond yet — check: journalctl -u ai-panel -n 50 --no-pager${RESET}"
fi

echo ""
echo -e "${GREEN}Update complete.${RESET}"
