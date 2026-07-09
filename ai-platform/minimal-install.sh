#!/usr/bin/env bash
# ============================================================
# AI for You — Minimal installer (v4.0)
# Downloads PRE-BUILT full React app. No build. No monorepo.
#
# Usage (as root on a fresh Ubuntu VPS):
#   export EMAIL=you@example.com
#   export DOMAIN=ai.abcomputers.info
#   export ADMIN_PASSWORD=your-secure-password
#   curl -fsSL http://install.abcomputers.info/minimal-install.sh -o /tmp/install.sh && sed -i 's/\r$//' /tmp/install.sh && bash /tmp/install.sh
# ============================================================
set -eu

DOMAIN="${DOMAIN:-ai.abcomputers.info}"
EMAIL="${EMAIL:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
TZ="${TZ:-Europe/London}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/ai-platform}"
RELEASE_URL="http://install.abcomputers.info/abc-ai-panel-v1.1.0.tar.gz"

RED='\033[31m'; GREEN='\033[32m'; BLUE='\033[34m'; BOLD='\033[1m'; RESET='\033[0m'
status() { printf "${BLUE}==>${RESET} ${BOLD}%s${RESET}\n" "$1" >&2; }
ok()     { printf "${GREEN}\u2714${RESET} %s\n" "$1" >&2; }
warn()   { printf "${RED}Warning${RESET}: %s\n" "$1" >&2; }
die()    { printf "${RED}Error${RESET}: %s\n" "$1" >&2; exit 1; }

generate_secret() { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p; }
require_root() { [ "$(id -u)" -ne 0 ] && die "Run as root"; }

# ── Step 1: Docker ──
if ! command -v docker &>/dev/null; then
  status "Installing Docker..."
  apt-get update -y && apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y && apt-get install -y docker-ce docker-compose-plugin
  systemctl enable docker && systemctl start docker
  ok "Docker installed"
else
  ok "Docker: $(docker --version)"
fi

# ── Step 2: Swap ──
if ! swapon --show | grep -q swap; then
  status "Creating swap..."
  fallocate -l 8G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=8192
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap created"
else
  ok "Swap already active"
fi

# ── Step 3: Download pre-built app ──
status "Downloading pre-built app..."
mkdir -p "$DEPLOY_DIR"
cd "$DEPLOY_DIR"
curl -fsSL "$RELEASE_URL" -o app.tar.gz || die "Download failed"
tar -xzf app.tar.gz || die "Extract failed"
mv abc-ai-panel-release app
rm app.tar.gz
ok "App extracted"

# ── Step 4: (no extra install needed — Dockerfile handles it) ──

# ── Step 5: Session secret ──
SESSION_SECRET="$(generate_secret)"

# ── Step 6: .env ──
if [ ! -f "$DEPLOY_DIR/.env" ]; then
  if [ -z "$ADMIN_PASSWORD" ]; then
    warn "ADMIN_PASSWORD not set. Using 'your-secure-password'"
    ADMIN_PASSWORD="your-secure-password"
  fi
  cat > "$DEPLOY_DIR/.env" <<EOF
DOMAIN=${DOMAIN}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
SESSION_SECRET=${SESSION_SECRET}
TZ=${TZ}
EOF
  chmod 600 "$DEPLOY_DIR/.env"
  ok ".env created"
else
  ok ".env exists (kept)"
  source "$DEPLOY_DIR/.env"
fi

# ── Step 7: Nginx config ──
mkdir -p "$DEPLOY_DIR/nginx"

# Base nginx.conf
cat > "$DEPLOY_DIR/nginx/nginx.conf" <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;
events { worker_connections 1024; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  log_format main '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent"';
  access_log /var/log/nginx/access.log main;
  sendfile on;
  keepalive_timeout 65;
  include /etc/nginx/conf.d/*.conf;
}
EOF

# SSL params
cat > "$DEPLOY_DIR/nginx/ssl.conf" <<'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 10m;
EOF

# AI conf
cat > "$DEPLOY_DIR/nginx/ai.conf" <<EOF
server {
    listen 80; server_name ${DOMAIN};
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl; http2 on; server_name ${DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/nginx/conf.d/ssl.conf;
    client_max_body_size 100M;
    location / {
        resolver 127.0.0.11 valid=30s;
        set \$upstream http://ai-panel:8080;
        proxy_pass \$upstream;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 600s;
    }
}
EOF

# ── Step 8: Docker Compose ──
cat > "$DEPLOY_DIR/docker/compose.yml" <<'COMPOSE'
version: "3.9"
networks:
  ai-net:
    driver: bridge
    name: ai-net
volumes:
  ollama-data:
  panel-data:
  certbot-conf:
  certbot-www:
services:
  nginx:
    image: nginx:1.27-alpine
    container_name: ai-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ../nginx:/etc/nginx/conf.d:ro
      - certbot-conf:/etc/letsencrypt:ro
      - certbot-www:/var/www/certbot:ro
    networks:
      - ai-net
    healthcheck:
      test: ["CMD", "nginx", "-t"]
      interval: 30s
      timeout: 10s
      retries: 3
  certbot:
    image: certbot/certbot:latest
    container_name: ai-certbot
    restart: "no"
    volumes:
      - certbot-conf:/etc/letsencrypt
      - certbot-www:/var/www/certbot
    entrypoint: >
      sh -c "trap exit TERM; while :; do certbot renew --quiet --webroot -w /var/www/certbot; sleep 12h; done"
  ollama:
    image: ollama/ollama:latest
    container_name: ai-ollama
    restart: unless-stopped
    mem_limit: 12g
    memswap_limit: 14g
    cpus: "6.0"
    volumes:
      - ollama-data:/root/.ollama
    networks:
      - ai-net
    environment:
      - OLLAMA_KEEP_ALIVE=5m
      - OLLAMA_HOST=0.0.0.0
      - OLLAMA_MAX_LOADED_MODELS=1
      - OLLAMA_NUM_PARALLEL=1
    healthcheck:
      test: ["CMD-SHELL", "ollama list >/dev/null 2>&1 || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 15
      start_period: 120s
  panel:
    image: abc-ai-panel:latest
    container_name: ai-panel
    restart: unless-stopped
    expose:
      - "8080"
    networks:
      - ai-net
    volumes:
      - panel-data:/app/data
    environment:
      - PORT=8080
      - FRONTEND_DIST=/app/public
      - OLLAMA_BASE_URL=http://ai-ollama:11434
      - DATA_DIR=/app/data
      - SESSION_SECRET=${SESSION_SECRET}
      - V1_API_KEY=local-ai-key
      - TZ=${TZ}
      - DOMAIN=${DOMAIN}
      - ADMIN_PASSWORD=${ADMIN_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "node -e \"fetch('http://localhost:8080/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 20s
COMPOSE

# ── Step 9: Build the panel image from extracted app ──
status "Building panel image from pre-built app..."
cd "$DEPLOY_DIR"
cat > Dockerfile <<'DOCKER'
FROM node:24-bookworm-slim
WORKDIR /app
COPY app/package.json .
RUN npm install --no-save express cors express-session pdf-parse archiver nodemailer express-rate-limit
COPY app/public ./public
COPY app/server ./server
ENV FRONTEND_DIST=/app/public PORT=8080
EXPOSE 8080
CMD ["node", "server/index.mjs"]
DOCKER
docker build -t abc-ai-panel:latest . || die "Image build failed"
ok "Image built"

# ── Step 10: Start stack ──
status "Starting stack..."
cd "$DEPLOY_DIR"
docker compose -f docker/compose.yml up -d || die "Stack failed"
ok "Stack started"

# ── Step 11: SSL ──
if [ -n "$EMAIL" ]; then
  status "Getting SSL certificate..."
  sleep 5
  docker stop ai-nginx
  docker run --rm \
    -v "$DEPLOY_DIR/certbot-conf:/etc/letsencrypt" \
    -v "$DEPLOY_DIR/certbot-www:/var/www/certbot" \
    -p 80:80 \
    certbot/certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN" \
    && ok "SSL ready" \
    || warn "SSL failed"
  docker start ai-nginx || docker restart ai-nginx
else
  warn "EMAIL not set — HTTPS will be configured later"
fi

# ── Step 12: Pull models ──
status "Pulling models..."
for model in llama3.2 qwen2.5:7b mistral:7b; do
  status "Pulling $model..."
  docker exec ai-ollama ollama pull "$model" || warn "Failed to pull $model"
done
ok "Models done"

# ── Done ──
echo ""
echo -e "${GREEN}============================================================${RESET}"
echo -e "${GREEN}  AI for You — Installed${RESET}"
echo -e "${GREEN}============================================================${RESET}"
echo "  URL:      https://${DOMAIN}"
echo "  Install:  curl -fsSL http://install.${DOMAIN}/install.sh | sh"
echo "  Dir:      ${DEPLOY_DIR}"
echo "  .env:     ${DEPLOY_DIR}/.env"
echo "  Logs:     docker logs ai-panel"
echo ""
echo "  Visit the URL and create your admin account."
echo ""
echo -e "  ${BOLD}Admin password:${RESET} ${ADMIN_PASSWORD}"
echo -e "${GREEN}============================================================${RESET}"
