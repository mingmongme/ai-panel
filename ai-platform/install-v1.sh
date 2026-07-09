#!/usr/bin/env bash
# ============================================================
# AI for You v1 — Clean installer
# Ollama + Caddy + Node.js 24 + Pre-built React app
# Bare metal. No Docker. No nginx.
# ============================================================
set -eu

DOMAIN="${DOMAIN:-ai.abcomputers.info}"
EMAIL="${EMAIL:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/ai-platform}"
RELEASE_URL="http://install.abcomputers.info/ai-for-you-v1.tar.gz"

RED='\033[31m'; GREEN='\033[32m'; BLUE='\033[34m'; BOLD='\033[1m'; RESET='\033[0m'
status() { printf "${BLUE}==>${RESET} ${BOLD}%s${RESET}\n" "$1" >&2; }
ok()     { printf "${GREEN}\u2714${RESET} %s\n" "$1" >&2; }
warn()   { printf "${RED}Warning${RESET}: %s\n" "$1" >&2; }
die()    { printf "${RED}Error${RESET}: %s\n" "$1" >&2; exit 1; }

generate_secret() { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p; }

# ── Step 1: Swap ──
if ! swapon --show | grep -q swap; then
  status "Creating swap..."
  fallocate -l 8G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=8192
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap created"
fi

# ── Step 2: Ollama ──
if ! command -v ollama &>/dev/null; then
  status "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
  ok "Ollama installed"
else
  ok "Ollama already installed"
fi
systemctl enable ollama 2>/dev/null || true
systemctl start ollama 2>/dev/null || true
sleep 3

# ── Step 3: Node.js 24 ──
if ! command -v node &>/dev/null || [ "$(node -v | cut -d'v' -f2 | cut -d'.' -f1)" != "24" ]; then
  status "Installing Node.js 24..."
  curl -fsSL "https://nodejs.org/dist/v24.11.0/node-v24.11.0-linux-x64.tar.xz" -o /tmp/node.tar.xz
  tar -xf /tmp/node.tar.xz -C /usr/local --strip-components=1
  rm /tmp/node.tar.xz
  ok "Node.js 24 installed"
fi

# ── Step 4: Caddy ──
if ! command -v caddy &>/dev/null; then
  status "Installing Caddy..."
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
  apt-get update && apt-get install -y caddy
  ok "Caddy installed"
else
  ok "Caddy already installed"
fi

# ── Step 5: Download app ──
status "Downloading app..."
mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"
curl -fsSL "$RELEASE_URL" -o app.tar.gz || die "Download failed"
tar -xzf app.tar.gz || die "Extract failed"
mv ai-for-you-v1 app
rm app.tar.gz
cd app
npm install --production 2>/dev/null || npm install --no-save express cors express-session pdf-parse archiver nodemailer express-rate-limit
ok "App ready"

# ── Step 6: .env ──
SESSION_SECRET="$(generate_secret)"
[ -z "$ADMIN_PASSWORD" ] && ADMIN_PASSWORD="your-secure-password"
cat > "$DEPLOY_DIR/.env" <<EOF
DOMAIN=${DOMAIN}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
SESSION_SECRET=${SESSION_SECRET}
TZ=Europe/London
PORT=8080
OLLAMA_BASE_URL=http://127.0.0.1:11434
FRONTEND_DIST=${DEPLOY_DIR}/app/public
DATA_DIR=${DEPLOY_DIR}/data
EOF
chmod 600 "$DEPLOY_DIR/.env"
mkdir -p "$DEPLOY_DIR/data"
ok ".env created"

# ── Step 7: Caddy config ──
cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
  reverse_proxy localhost:8080
}
EOF
caddy reload 2>/dev/null || systemctl restart caddy 2>/dev/null || true
ok "Caddy configured"

# ── Step 8: Systemd service ──
cat > /etc/systemd/system/ai-panel.service <<EOF
[Unit]
Description=AI for You
After=network.target ollama.service

[Service]
Type=simple
User=root
WorkingDirectory=${DEPLOY_DIR}/app
EnvironmentFile=${DEPLOY_DIR}/.env
ExecStart=/usr/local/bin/node server/index.mjs
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ai-panel
systemctl start ai-panel
sleep 3

if curl -fsS http://127.0.0.1:8080/ >/dev/null 2>&1; then
  ok "App running on port 8080"
else
  warn "App slow to start. Check: journalctl -u ai-panel -f"
fi

# ── Step 9: Models ──
status "Pulling models..."
for model in llama3.2 qwen2.5:7b mistral:7b; do
  ollama pull "$model" || warn "Failed: $model"
done
ok "Models done"

# ── Done ──
echo ""
echo -e "${GREEN}============================================================${RESET}"
echo -e "${GREEN}  AI for You v1 — Installed${RESET}"
echo -e "${GREEN}============================================================${RESET}"
echo "  URL:      https://${DOMAIN}"
echo "  Logs:     journalctl -u ai-panel -f"
echo "  Restart:  systemctl restart ai-panel"
echo ""
echo -e "  ${BOLD}Admin password:${RESET} ${ADMIN_PASSWORD}"
echo -e "${GREEN}============================================================${RESET}"
