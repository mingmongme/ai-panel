#!/usr/bin/env bash
# AI for You — one-command installer
# Bare metal (no Docker): Ollama + Node.js 24 + Caddy (auto HTTPS) + systemd
#
# Usage:
#   export DOMAIN=ai.abcomputers.info
#   export EMAIL=you@example.com
#   curl -fsSL https://raw.githubusercontent.com/mingmongme/ai-panel/main/ai-platform/install.sh | bash
#
# On first visit the app shows a setup screen — create your admin account there.
# No ADMIN_PASSWORD env var needed.
#
# Adding a new env var? Update `ai-platform/.env.example` in the same change
# (the app.env heredoc below AND any new process.env[...] read in
# artifacts/api-server/src must be documented there). Verify with:
#   bash ai-platform/scripts/check-env-example.sh
set -euo pipefail

DOMAIN="${DOMAIN:?Set DOMAIN, e.g. export DOMAIN=ai.abcomputers.info}"
EMAIL="${EMAIL:?Set EMAIL for the SSL certificate, e.g. export EMAIL=you@example.com}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/ai-platform}"
NODE_VERSION="24.11.0"
TARBALL_URL="https://raw.githubusercontent.com/mingmongme/ai-panel/main/ai-platform/ai-for-you-v1.tar.gz"
REQUIRED_KEYS_URL="https://raw.githubusercontent.com/mingmongme/ai-panel/main/ai-platform/required-env-keys.txt"
MODELS="${MODELS:-llama3.2 llama3.1 qwen2.5:7b mistral:7b deepseek-r1:7b phi4}"

RED='\033[31m'; GREEN='\033[32m'; BLUE='\033[34m'; BOLD='\033[1m'; RESET='\033[0m'
status() { printf "${BLUE}==>${RESET} ${BOLD}%s${RESET}\n" "$1"; }
ok()     { printf "${GREEN}\u2714${RESET} %s\n" "$1"; }
die()    { printf "${RED}Error:${RESET} %s\n" "$1" >&2; exit 1; }

# Fails loudly if any key listed in required-env-keys.txt is missing or blank
# in the given env file. Prevents starting/restarting the service with a
# half-configured app.env (e.g. a required key appended blank by a future
# sync step).
validate_required_env() {
  local env_file="$1"
  local keys_file="$2"
  [ -s "$keys_file" ] || die "Could not load the required-config checklist ($keys_file is missing or empty) — refusing to start with unverified config. Check your network/GitHub access and re-run."
  local missing=()
  while IFS= read -r key || [ -n "$key" ]; do
    key="$(echo "$key" | sed 's/#.*//' | xargs)"
    [ -z "$key" ] && continue
    local value
    value="$(grep -E "^${key}=" "$env_file" | tail -n1 | cut -d'=' -f2- | xargs)" || true
    if [ -z "$value" ]; then
      missing+=("$key")
    fi
  done < "$keys_file"
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "" >&2
    printf "${RED}Error:${RESET} the following required config values are missing or blank in %s:\n" "$env_file" >&2
    for k in "${missing[@]}"; do printf "  - %s\n" "$k" >&2; done
    echo "Set a real value for each key above, then re-run this script (or restart the service)." >&2
    exit 1
  fi
}

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo bash install.sh)"

status "Step 1/9 — Swap"
if ! swapon --show | grep -q swap; then
  fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "4G swap created"
else
  ok "Swap already present"
fi

status "Step 2/9 — Ollama"
if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
systemctl enable --now ollama
sleep 2
ok "Ollama running"

status "Step 3/9 — Node.js ${NODE_VERSION}"
if ! command -v node &>/dev/null || [ "$(node -v)" != "v${NODE_VERSION}" ]; then
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o /tmp/node.tar.xz
  tar -xf /tmp/node.tar.xz -C /usr/local --strip-components=1
  rm -f /tmp/node.tar.xz
fi
ok "Node.js $(node -v)"

status "Step 4/9 — Caddy"
if ! command -v caddy &>/dev/null; then
  apt-get update -y -qq
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    -o /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y -qq
  apt-get install -y -qq caddy
fi
ok "Caddy $(caddy version 2>/dev/null | head -1)"

status "Step 5/9 — Chromium (browser agent)"
CHROMIUM_BIN=""
for candidate in /usr/bin/chromium /usr/bin/chromium-browser; do
  if [ -x "$candidate" ]; then CHROMIUM_BIN="$candidate"; break; fi
done
if [ -z "$CHROMIUM_BIN" ]; then
  apt-get update -y -qq
  if apt-get install -y -qq chromium 2>/dev/null && [ -x /usr/bin/chromium ]; then
    CHROMIUM_BIN="/usr/bin/chromium"
  elif apt-get install -y -qq chromium-browser 2>/dev/null && [ -x /usr/bin/chromium-browser ]; then
    CHROMIUM_BIN="/usr/bin/chromium-browser"
  elif command -v snap &>/dev/null && snap install chromium 2>/dev/null && [ -x /snap/bin/chromium ]; then
    CHROMIUM_BIN="/snap/bin/chromium"
  fi
fi
if [ -n "$CHROMIUM_BIN" ] && "$CHROMIUM_BIN" --version &>/dev/null; then
  ok "Chromium found: $("$CHROMIUM_BIN" --version)"
else
  CHROMIUM_BIN=""
  echo -e "${RED}Warning:${RESET} could not install/verify Chromium. The browser agent feature will be unavailable until you install it manually and set CHROMIUM_PATH in ${DEPLOY_DIR}/app.env."
fi

status "Step 6/9 — App"
mkdir -p "$DEPLOY_DIR"
curl -fsSL "$TARBALL_URL" -o /tmp/ai-for-you.tar.gz || die "Could not download app from GitHub"
rm -rf "$DEPLOY_DIR/app"
mkdir -p "$DEPLOY_DIR/app"
tar -xzf /tmp/ai-for-you.tar.gz -C "$DEPLOY_DIR/app"
rm -f /tmp/ai-for-you.tar.gz
cd "$DEPLOY_DIR/app"
npm install --omit=dev --no-audit --no-fund
mkdir -p "$DEPLOY_DIR/data"
ok "App installed to $DEPLOY_DIR/app"

status "Step 7/9 — Configuration"
SESSION_SECRET="$(openssl rand -hex 32)"
cat > "$DEPLOY_DIR/app.env" <<EOF
NODE_ENV=production
PORT=8080
DOMAIN=${DOMAIN}
SESSION_SECRET=${SESSION_SECRET}
OLLAMA_BASE_URL=http://127.0.0.1:11434
FRONTEND_DIST=${DEPLOY_DIR}/app/public
DATA_DIR=${DEPLOY_DIR}/data
FILES_ROOT=${DEPLOY_DIR}/data/projects
LOG_LEVEL=info
EOF
if [ -n "$CHROMIUM_BIN" ]; then
  echo "CHROMIUM_PATH=${CHROMIUM_BIN}" >> "$DEPLOY_DIR/app.env"
fi
chmod 600 "$DEPLOY_DIR/app.env"
ok "Config written to $DEPLOY_DIR/app.env"

curl -fsSL "$REQUIRED_KEYS_URL" -o "$DEPLOY_DIR/required-env-keys.txt" || die "Could not download required-env-keys.txt from GitHub — cannot verify config, aborting before starting the service."
validate_required_env "$DEPLOY_DIR/app.env" "$DEPLOY_DIR/required-env-keys.txt"
ok "Required config values present"

status "Step 8/9 — systemd + Caddy"
cat > /etc/systemd/system/ai-panel.service <<EOF
[Unit]
Description=AI for You
After=network.target ollama.service

[Service]
Type=simple
User=root
WorkingDirectory=${DEPLOY_DIR}/app
EnvironmentFile=${DEPLOY_DIR}/app.env
Environment=UV_THREADPOOL_SIZE=16
ExecStart=/usr/local/bin/node server/index.mjs
Restart=always
RestartSec=5
StandardOutput=append:/var/log/ai-panel.log
StandardError=append:/var/log/ai-panel.log

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ai-panel

cat > /etc/caddy/Caddyfile <<EOF
{
  email ${EMAIL}
}

${DOMAIN} {
  reverse_proxy localhost:8080
  encode gzip
}
EOF
systemctl enable --now caddy
systemctl reload caddy || systemctl restart caddy
ok "Service + reverse proxy configured"

status "Step 9/9 — Pulling models (${MODELS})"
for model in $MODELS; do
  if [ "$model" = "phi4" ]; then
    echo -e "${RED}Note:${RESET} phi4 is a 14B model and needs ~8 GB RAM to run — more than half this VPS's memory."
    echo "      Set OLLAMA_MAX_LOADED_MODELS=1 in ${DEPLOY_DIR}/app.env (or systemd env) and load phi4 by itself,"
    echo "      not alongside another model, to avoid running out of memory."
  fi
  ollama pull "$model" || echo "  (skipped $model — failed to pull)"
done
ok "Models ready"

sleep 3
if curl -fsS http://127.0.0.1:8080/ >/dev/null 2>&1; then
  ok "App responding on port 8080"
else
  echo -e "${RED}App did not respond yet — check: journalctl -u ai-panel -n 50 --no-pager${RESET}"
fi

echo ""
echo -e "${GREEN}================================================${RESET}"
echo -e "${GREEN}  AI for You — installed${RESET}"
echo -e "${GREEN}================================================${RESET}"
echo "  URL:          https://${DOMAIN}"
echo "  Admin user:   create your account on first visit (setup screen)"
echo "  Logs:         journalctl -u ai-panel -f"
echo "  Restart:      systemctl restart ai-panel"
echo "  Caddy logs:   journalctl -u caddy -f"
if [ -n "$CHROMIUM_BIN" ]; then
  echo "  Browser agent: Chromium ready ($CHROMIUM_BIN) — enable it in Settings"
else
  echo -e "  Browser agent: ${RED}unavailable${RESET} — install Chromium manually and set CHROMIUM_PATH in ${DEPLOY_DIR}/app.env, then: systemctl restart ai-panel"
fi
echo -e "${GREEN}================================================${RESET}"
if echo "$MODELS" | grep -qw "phi4"; then
  echo ""
  echo -e "${RED}Reminder:${RESET} phi4 needs ~8 GB RAM. Load it alone (set OLLAMA_MAX_LOADED_MODELS=1)"
  echo "          — don't run it loaded at the same time as another model."
fi
