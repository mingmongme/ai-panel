#!/usr/bin/env bash
# ============================================================
# AI for You — Bare-metal installer (no Docker, no nginx)
# Everything runs directly on the host. Clean and simple.
#
# Usage (as root on a fresh Ubuntu VPS):
#   export EMAIL=you@example.com
#   export DOMAIN=ai.abcomputers.info
#   export ADMIN_PASSWORD=your-secure-password
#   curl -fsSL http://install.abcomputers.info/bare-metal-install.sh -o /tmp/install.sh && bash /tmp/install.sh
# ============================================================
set -eu

DOMAIN="${DOMAIN:-ai.abcomputers.info}"
EMAIL="${EMAIL:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
TZ="${TZ:-Europe/London}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/ai-platform}"
RELEASE_URL="https://github.com/mingmongme/ai-panel/releases/download/v1.1.0/abc-ai-panel-v1.1.0.tar.gz"

RED='\033[31m'; GREEN='\033[32m'; BLUE='\033[34m'; BOLD='\033[1m'; RESET='\033[0m'
status() { printf "${BLUE}==>${RESET} ${BOLD}%s${RESET}\n" "$1" >&2; }
ok()     { printf "${GREEN}\u2714${RESET} %s\n" "$1" >&2; }
warn()   { printf "${RED}Warning${RESET}: %s\n" "$1" >&2; }
die()    { printf "${RED}Error${RESET}: %s\n" "$1" >&2; exit 1; }

generate_secret() { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p; }
require_root() { [ "$(id -u)" -ne 0 ] && die "Run as root"; }

# ── Step 1: Basic tools ──
status "Installing basic tools..."
apt-get update -y && apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common
ok "Tools ready"

# ── Step 2: Swap ──
if ! swapon --show | grep -q swap; then
  status "Creating swap..."
  fallocate -l 8G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=8192
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap created"
fi

# ── Step 3: Ollama ──
if ! command -v ollama &>/dev/null; then
  status "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
  ok "Ollama installed"
else
  ok "Ollama already installed"
fi

# Start Ollama service
systemctl enable ollama
systemctl start ollama
sleep 3

# ── Step 4: Node.js 24 ──
if ! command -v node &>/dev/null || [ "$(node -v | cut -d'v' -f2 | cut -d'.' -f1)" != "24" ]; then
  status "Installing Node.js 24..."
  NODE_TARBALL="node-v24.11.0-linux-x64.tar.xz"
  curl -fsSL "https://nodejs.org/dist/v24.11.0/${NODE_TARBALL}" -o "/tmp/${NODE_TARBALL}" || die "Node download failed"
  tar -xf "/tmp/${NODE_TARBALL}" -C /usr/local --strip-components=1
  rm "/tmp/${NODE_TARBALL}"
  ok "Node.js 24 installed"
else
  ok "Node.js: $(node -v)"
fi

# ── Step 5: Download pre-built app ──
status "Downloading pre-built app..."
mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"
curl -fsSL "$RELEASE_URL" -o app.tar.gz || die "Download failed"
tar -xzf app.tar.gz || die "Extract failed"
mv abc-ai-panel-release app
rm app.tar.gz
cd app
npm install --production 2>/dev/null || npm install --no-save express cors express-session pdf-parse archiver nodemailer express-rate-limit
ok "App ready"

# ── Step 6: .env ──
SESSION_SECRET="$(generate_secret)"
if [ -z "$ADMIN_PASSWORD" ]; then
  warn "ADMIN_PASSWORD not set. Using 'your-secure-password'"
  ADMIN_PASSWORD="your-secure-password"
fi
cat > "$DEPLOY_DIR/.env" <<EOF
DOMAIN=${DOMAIN}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
SESSION_SECRET=${SESSION_SECRET}
TZ=${TZ}
PORT=8080
OLLAMA_BASE_URL=http://127.0.0.1:11434
FRONTEND_DIST=${DEPLOY_DIR}/app/public
DATA_DIR=${DEPLOY_DIR}/data
EOF
chmod 600 "$DEPLOY_DIR/.env"
mkdir -p "$DEPLOY_DIR/data"
ok ".env created"

# ── Step 7: Systemd service ──
cat > /etc/systemd/system/ai-panel.service <<EOF
[Unit]
Description=AI for You Panel
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
ok "Service created"

# ── Step 8: SSL with certbot ──
if [ -n "$EMAIL" ]; then
  status "Installing certbot..."
  apt-get install -y certbot 2>/dev/null || snap install certbot --classic 2>/dev/null || true

  status "Getting SSL certificate..."
  # Stop anything on port 80
  systemctl stop ai-panel 2>/dev/null || true
  # Get cert
  certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN" || warn "SSL failed"

  # HTTP redirect service (tiny Python script on port 80)
  cat > /etc/systemd/system/ai-redirect.service <<'REDIR'
[Unit]
Description=HTTP to HTTPS redirect
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -c "import socket,sys; s=socket.socket(socket.AF_INET,socket.SOCK_STREAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('',80)); s.listen(100)
while True:
  c,a=s.accept(); req=c.recv(1024)
  host=[l.split(b':')[1].strip().decode() for l in req.split(b'\r\n') if l.lower().startswith(b'host:')]
  host=host[0] if host else 'localhost'
  c.send(b'HTTP/1.1 301 Moved Permanently\r\nLocation: https://'+host.encode()+b'%s\r\nConnection: close\r\n\r\n')
  c.close()"
Restart=always
REDIR
  systemctl daemon-reload
  systemctl enable ai-redirect
  systemctl start ai-redirect
  ok "HTTP redirect active"
else
  warn "EMAIL not set — HTTPS will be configured later"
fi

# ── Step 9: Start the app ──
status "Starting AI panel..."
systemctl start ai-panel
sleep 3

# Check it's running
if curl -fsS http://127.0.0.1:8080/ >/dev/null 2>&1; then
  ok "Panel running on port 8080"
else
  warn "Panel may need a moment. Check: journalctl -u ai-panel -f"
fi

# ── Step 10: Pull models ──
status "Pulling models..."
for model in llama3.2 qwen2.5:7b mistral:7b; do
  status "Pulling $model..."
  ollama pull "$model" || warn "Failed to pull $model"
done
ok "Models done"

# ── Done ──
echo ""
echo -e "${GREEN}============================================================${RESET}"
echo -e "${GREEN}  AI for You — Installed (Bare Metal)${RESET}"
echo -e "${GREEN}============================================================${RESET}"
echo "  URL:      https://${DOMAIN}"
echo "  Dir:      ${DEPLOY_DIR}"
echo "  .env:     ${DEPLOY_DIR}/.env"
echo "  Logs:     journalctl -u ai-panel -f"
echo "  Restart:  systemctl restart ai-panel"
echo ""
echo "  Visit the URL and create your admin account."
echo ""
echo -e "  ${BOLD}Admin password:${RESET} ${ADMIN_PASSWORD}"
echo -e "${GREEN}============================================================${RESET}"
