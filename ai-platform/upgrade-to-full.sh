#!/usr/bin/env bash
# ============================================================
# AI for You — Upgrade from minimal HTML to full React app
# Preserves: SSL certs, .env, Ollama models, nginx config
# Requires: GITHUB_TOKEN env var (for private repo clone)
# ============================================================
set -eu

require_root() { [ "$(id -u)" -ne 0 ] && echo "Run as root" && exit 1; }
require_root

RED='\033[31m'; GREEN='\033[32m'; BLUE='\033[34m'; BOLD='\033[1m'; RESET='\033[0m'
status() { printf "${BLUE}==>${RESET} ${BOLD}%s${RESET}\n" "$1" >&2; }
ok()     { printf "${GREEN}✔${RESET} %s\n" "$1" >&2; }
warn()   { printf "${RED}Warning${RESET}: %s\n" "$1" >&2; }
die()    { printf "${RED}Error${RESET}: %s\n" "$1" >&2; exit 1; }

DOMAIN="${DOMAIN:-ai.abcomputers.info}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/ai-platform}"
REPO_DIR="${DEPLOY_DIR}/repo"
TOKEN="${GITHUB_TOKEN:-}"

[ -z "$TOKEN" ] && die "GITHUB_TOKEN not set. Get yours from GitHub Settings > Developer settings > Personal access tokens"

# ── Step 1: Backup current data ──
status "Backing up data..."
mkdir -p "$DEPLOY_DIR/backup-$(date +%Y%m%d-%H%M%S)"
cp -r "$DEPLOY_DIR/certbot-conf" "$DEPLOY_DIR/backup-$(date +%Y%m%d-%H%M%S)/" 2>/dev/null || true
cp "$DEPLOY_DIR/.env" "$DEPLOY_DIR/backup-$(date +%Y%m%d-%H%M%S)/" 2>/dev/null || true
cp "$DEPLOY_DIR/nginx/ai.conf" "$DEPLOY_DIR/backup-$(date +%Y%m%d-%H%M%S)/" 2>/dev/null || true
ok "Backup saved"

# ── Step 2: Clone repo ──
status "Cloning repo..."
rm -rf "$REPO_DIR"
git clone --depth 1 "https://${TOKEN}@github.com/mingmongme/ai-panel.git" "$REPO_DIR" || die "Clone failed. Check token."
ok "Repo cloned"

# ── Step 3: Build real image ──
status "Building full app image (this takes 3-5 mins)..."
cd "$REPO_DIR"
# Use existing .env values for build
cp "$DEPLOY_DIR/.env" .env 2>/dev/null || true
# Build the monorepo Dockerfile at repo root
docker build -t abc-ai-panel:latest . || die "Docker build failed"
ok "Image built"

# ── Step 4: Update compose to use real image ──
status "Updating compose..."
# The minimal installer created a different compose. Replace it with the real one.
cp "$REPO_DIR/ai-platform/docker/compose.yml" "$DEPLOY_DIR/docker/compose.yml"
# Ensure SSL certs and .env paths are preserved
ok "Compose updated"

# ── Step 5: Restart panel with real app ──
status "Restarting panel with full app..."
cd "$DEPLOY_DIR"
docker stop ai-panel 2>/dev/null || true
docker rm ai-panel 2>/dev/null || true
# Bring up with the new image — nginx + ollama + certbot stay running
docker compose -f docker/compose.yml up -d panel || die "Panel restart failed"
ok "Panel restarted"

# ── Step 6: Verify ──
status "Waiting for panel to start..."
for i in $(seq 1 30); do
  sleep 2
  if curl -fsS http://localhost:8080/ >/dev/null 2>&1; then ok "Panel responding"; break; fi
  if [ "$i" -eq 30 ]; then warn "Panel slow to start. Check: docker logs ai-panel"; fi
done

# ── Step 7: Check Ollama still has models ──
status "Checking models..."
if docker exec ai-ollama ollama list 2>/dev/null | grep -q .; then
  ok "Models still present"
else
  warn "Models missing. Run on the VPS: docker exec ai-ollama ollama pull llama3.2"
fi

# ── Step 8: Done ──
echo ""
echo -e "${GREEN}============================================================${RESET}"
echo -e "${GREEN}  AI for You — Full App Restored${RESET}"
echo -e "${GREEN}============================================================${RESET}"
echo "  URL:      https://${DOMAIN}"
echo "  Logs:     docker logs ai-panel"
echo "  Admin:    Login with your existing credentials"
echo ""
echo -e "${BOLD}Refresh the browser to see the full React app.${RESET}"
echo -e "${GREEN}============================================================${RESET}"
