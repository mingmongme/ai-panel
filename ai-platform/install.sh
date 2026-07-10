#!/usr/bin/env bash
# AI for You — one-command installer
# Bare metal (no Docker): Ollama + Node.js 24 + Caddy (auto HTTPS) + systemd
#
# Usage:
#   export DOMAIN=ai.abcomputers.info
#   export EMAIL=you@example.com
#   export ADMIN_PASSWORD=choose-a-strong-password
#   curl -fsSL https://raw.githubusercontent.com/mingmongme/ai-panel/main/ai-platform/install.sh -o /tmp/install.sh
#   bash /tmp/install.sh
set -euo pipefail

DOMAIN="${DOMAIN:?Set DOMAIN, e.g. export DOMAIN=ai.abcomputers.info}"
EMAIL="${EMAIL:?Set EMAIL for the SSL certificate, e.g. export EMAIL=you@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?Set ADMIN_PASSWORD, e.g. export ADMIN_PASSWORD=your-password}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/ai-platform}"
NODE_VERSION="24.11.0"
TARBALL_URL="https://raw.githubusercontent.com/mingmongme/ai-panel/main/ai-platform/ai-for-you-v1.tar.gz"
MODELS="${MODELS:-llama3.2 llama3.1 qwen2.5:7b mistral:7b deepseek-r1:7b phi4}"

RED='\033[31m'; GREEN='\033[32m'; BLUE='\033[34m'; BOLD='\033[1m'; RESET='\033[0m'
status() { printf "${BLUE}==>${RESET} ${BOLD}%s${RESET}\n" "$1"; }
ok()     { printf "${GREEN}\u2714${RESET} %s\n" "$1"; }
die()    { printf "${RED}Error:${RESET} %s\n" "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo bash install.sh)"

status "Step 1/8 — Swap"
if ! swapon --show | grep -q swap; then
  fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "4G swap created"
else
  ok "Swap already present"
fi

status "Step 2/8 — Ollama"
if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
systemctl enable --now ollama
sleep 2
ok "Ollama running"

status "Step 3/8 — Node.js ${NODE_VERSION}"
if ! command -v node &>/dev/null || [ "$(node -v)" != "v${NODE_VERSION}" ]; then
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o /tmp/node.tar.xz
  tar -xf /tmp/node.tar.xz -C /usr/local --strip-components=1
  rm -f /tmp/node.tar.xz
fi
ok "Node.js $(node -v)"

status "Step 4/8 — Caddy"
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

status "Step 5/8 — App"
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

status "Step 6/8 — Configuration"
SESSION_SECRET="$(openssl rand -hex 32)"
cat > "$DEPLOY_DIR/app.env" <<EOF
NODE_ENV=production
PORT=8080
DOMAIN=${DOMAIN}
ADMIN_USERNAME=admin
ADMIN_PASSWORD=${ADMIN_PASSWORD}
SESSION_SECRET=${SESSION_SECRET}
OLLAMA_BASE_URL=http://127.0.0.1:11434
FRONTEND_DIST=${DEPLOY_DIR}/app/public
DATA_DIR=${DEPLOY_DIR}/data
FILES_ROOT=${DEPLOY_DIR}/data/projects
LOG_LEVEL=info
EOF
chmod 600 "$DEPLOY_DIR/app.env"
ok "Config written to $DEPLOY_DIR/app.env"

status "Step 7/8 — systemd + Caddy"
cat > /etc/systemd/system/ai-panel.service <<EOF
[Unit]
Description=AI for You
After=network.target ollama.service

[Service]
Type=simple
User=root
WorkingDirectory=${DEPLOY_DIR}/app
EnvironmentFile=${DEPLOY_DIR}/app.env
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

status "Step 8/8 — Pulling models (${MODELS})"
for model in $MODELS; do
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
echo "  Admin user:   admin"
echo "  Admin pass:   ${ADMIN_PASSWORD}"
echo "  Logs:         journalctl -u ai-panel -f"
echo "  Restart:      systemctl restart ai-panel"
echo "  Caddy logs:   journalctl -u caddy -f"
echo -e "${GREEN}================================================${RESET}"
