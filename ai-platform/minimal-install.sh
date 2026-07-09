#!/usr/bin/env bash
# ============================================================
# AI for You — Minimal installer (v3.7)
# No build step. No monorepo. 600 lines. Bulletproof.
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

RED='\033[31m'; GREEN='\033[32m'; BLUE='\033[34m'; BOLD='\033[1m'; RESET='\033[0m'
status() { printf "${BLUE}==>${RESET} ${BOLD}%s${RESET}\n" "$1" >&2; }
ok()     { printf "${GREEN}✔${RESET} %s\n" "$1" >&2; }
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
fi

# ── Step 3: Dirs ──
rm -rf "$DEPLOY_DIR" && mkdir -p "$DEPLOY_DIR"/{nginx,docker,src,certbot-conf,certbot-www}

# ── Step 4: .env ──
SESSION_SECRET=$(generate_secret)
[ -z "$ADMIN_PASSWORD" ] && ADMIN_PASSWORD=$(openssl rand -hex 8)
cat > "$DEPLOY_DIR/.env" <<EOF
DOMAIN=$DOMAIN
EMAIL=$EMAIL
SESSION_SECRET=$SESSION_SECRET
ADMIN_PASSWORD=$ADMIN_PASSWORD
OLLAMA_BASE_URL=http://ai-ollama:11434
TZ=$TZ
EOF
chmod 600 "$DEPLOY_DIR/.env"

# ── Step 5: nginx config (HTTP first, SSL later) ──
cat > "$DEPLOY_DIR/nginx/ai.conf" <<'EOF'
server {
    listen 80;
    server_name __DOMAIN__;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location ~ /\. { deny all; return 404; }
    client_max_body_size 100M;
    location / {
        resolver 127.0.0.11 valid=30s;
        set $upstream http://ai-panel:8080;
        proxy_pass $upstream;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_read_timeout 600s;
    }
}
EOF
sed -i "s|__DOMAIN__|$DOMAIN|g" "$DEPLOY_DIR/nginx/ai.conf"

cat > "$DEPLOY_DIR/nginx/certbot.conf" <<EOF
server { listen 80; server_name $DOMAIN; location /.well-known/acme-challenge/ { root /var/www/certbot; } }
EOF

cat > "$DEPLOY_DIR/nginx/ssl.conf" <<'EOF'
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers ECDHE+AESGCM:ECDHE+CHACHA20:!aNULL:!MD5;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
EOF

# ── Step 6: Compose ──
cat > "$DEPLOY_DIR/docker/compose.yml" <<'EOF'
name: ai-platform
networks:
  ai-net: { driver: bridge }
volumes:
  ollama-data: { driver: local }
  panel-data: { driver: local }
services:
  nginx:
    image: nginx:1.27-alpine
    container_name: ai-nginx
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ../nginx:/etc/nginx/conf.d:ro
      - ../certbot-conf:/etc/letsencrypt:ro
      - ../certbot-www:/var/www/certbot:ro
    networks: [ai-net]
  certbot:
    image: certbot/certbot:latest
    container_name: ai-certbot
    restart: "no"
    volumes:
      - ../certbot-conf:/etc/letsencrypt
      - ../certbot-www:/var/www/certbot
    entrypoint: >
      sh -c "trap exit TERM; while :; do certbot renew --quiet --webroot -w /var/www/certbot; sleep 12h; done"
  ollama:
    image: ollama/ollama:latest
    container_name: ai-ollama
    restart: unless-stopped
    mem_limit: 12g
    memswap_limit: 14g
    cpus: "6.0"
    volumes: [ollama-data:/root/.ollama]
    networks: [ai-net]
    environment:
      OLLAMA_KEEP_ALIVE: 5m
      OLLAMA_HOST: 0.0.0.0
      OLLAMA_MAX_LOADED_MODELS: 1
      OLLAMA_NUM_PARALLEL: 1
  panel:
    build: { context: ../src, dockerfile: Dockerfile }
    container_name: ai-panel
    restart: unless-stopped
    expose: ["8080"]
    networks: [ai-net]
    volumes: [panel-data:/app/data, /var/run/docker.sock:/var/run/docker.sock]
    environment:
      PORT: 8080
      OLLAMA_BASE_URL: http://ai-ollama:11434
      DATA_DIR: /app/data
      SESSION_SECRET: ${SESSION_SECRET}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      DOMAIN: ${DOMAIN}
EOF
ln -sf "$DEPLOY_DIR/.env" "$DEPLOY_DIR/docker/.env"

# ── Step 7: Backend (Express + session + Ollama proxy) ──
mkdir -p "$DEPLOY_DIR/src"

cat > "$DEPLOY_DIR/src/server.js" <<'NODESRC'
const express = require("express");
const cors = require("cors");
const session = require("express-session");
const path = require("path");
const fs = require("fs");
const crypto = require("crypto");

const app = express();
app.set("trust proxy", 1);
app.use(cors({ origin: true, credentials: true }));
app.use(express.json({ limit: "5mb" }));
app.use(session({
  secret: process.env.SESSION_SECRET || "change-me",
  resave: false, saveUninitialized: false,
  cookie: { httpOnly: true, secure: false, sameSite: "lax", maxAge: 7 * 24 * 60 * 60 * 1000 }
}));

const DATA_DIR = process.env.DATA_DIR || "/app/data";
const USERS_FILE = path.join(DATA_DIR, "users.json");
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

function loadUsers() {
  try { return JSON.parse(fs.readFileSync(USERS_FILE, "utf8")); }
  catch { return []; }
}
function saveUsers(users) {
  fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2));
}

const OLLAMA = process.env.OLLAMA_BASE_URL || "http://localhost:11434";

function hash(pw) { return crypto.createHash("sha256").update(pw + "salt").digest("hex"); }

// Auth routes
app.get("/api/auth/setup-required", (_req, res) => {
  const users = loadUsers();
  res.json({ required: users.length === 0 });
});

app.post("/api/auth/setup", (req, res) => {
  const { username, password, displayName } = req.body;
  const users = loadUsers();
  if (users.length > 0) { res.status(403).json({ error: "Setup already completed" }); return; }
  if (!username || !password || username.length < 2 || password.length < 8) {
    res.status(400).json({ error: "Username (min 2) and password (min 8) required" }); return;
  }
  const user = { id: crypto.randomBytes(16).toString("hex"), username: username.trim(), passwordHash: hash(password), displayName: displayName?.trim() || username.trim(), isAdmin: true, createdAt: Date.now() };
  users.push(user); saveUsers(users);
  req.session.userId = user.id; req.session.isAdmin = user.isAdmin;
  res.json({ id: user.id, username: user.username, displayName: user.displayName, avatarColor: "#38BDF8", isAdmin: user.isAdmin, createdAt: user.createdAt, lastLoginAt: Date.now() });
});

app.post("/api/auth/login", (req, res) => {
  const { username, password } = req.body;
  const users = loadUsers();
  const user = users.find(u => u.username === username && u.passwordHash === hash(password));
  if (!user) { res.status(401).json({ error: "Invalid credentials" }); return; }
  req.session.userId = user.id; req.session.isAdmin = user.isAdmin;
  res.json({ id: user.id, username: user.username, displayName: user.displayName, avatarColor: "#38BDF8", isAdmin: user.isAdmin, createdAt: user.createdAt, lastLoginAt: Date.now() });
});

app.post("/api/auth/logout", (req, res) => {
  req.session.destroy(() => {}); res.json({ ok: true });
});

app.get("/api/auth/me", (req, res) => {
  if (!req.session.userId) { res.status(401).json({ error: "Not authenticated" }); return; }
  const users = loadUsers();
  const user = users.find(u => u.id === req.session.userId);
  if (!user) { res.status(401).json({ error: "User not found" }); return; }
  res.json({ id: user.id, username: user.username, displayName: user.displayName, avatarColor: "#38BDF8", isAdmin: user.isAdmin, createdAt: user.createdAt, lastLoginAt: Date.now() });
});

function requireAuth(req, res, next) {
  if (!req.session.userId) { res.status(401).json({ error: "Not authenticated" }); return; }
  next();
}

// Ollama proxy
app.get("/api/models", requireAuth, async (_req, res) => {
  try {
    const r = await fetch(`${OLLAMA}/api/tags`);
    const data = await r.json();
    res.json(data);
  } catch (e) { res.status(502).json({ error: "Ollama unreachable", detail: e.message }); }
});

app.post("/api/chat", requireAuth, async (req, res) => {
  try {
    const { model, messages } = req.body;
    const r = await fetch(`${OLLAMA}/api/chat`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model, messages, stream: true }),
    });
    if (!r.ok) { res.status(r.status).json({ error: "Ollama error" }); return; }
    res.setHeader("Content-Type", "application/x-ndjson");
    if (!r.body) { res.status(502).json({ error: "No body" }); return; }
    const reader = r.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      res.write(Buffer.from(value));
    }
    res.end();
  } catch (e) { res.status(502).json({ error: "Ollama unreachable", detail: e.message }); }
});

// Serve static frontend
const PUBLIC = path.join(__dirname, "public");
app.use(express.static(PUBLIC));
app.use((_req, res) => res.sendFile(path.join(PUBLIC, "index.html")));

const PORT = process.env.PORT || 8080;
app.listen(PORT, () => console.log(`Server on port ${PORT}`));
NODESRC

# ── Step 8: Frontend (single HTML file, vanilla JS) ──
mkdir -p "$DEPLOY_DIR/src/public"

cat > "$DEPLOY_DIR/src/public/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AI for You</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:Inter,system-ui,sans-serif;background:#0B1F3A;color:#e2e8f0;height:100vh;display:flex}
.sidebar{width:260px;background:#0f172a;border-right:1px solid #1e293b;display:flex;flex-direction:column}
.sidebar-header{padding:16px;border-bottom:1px solid #1e293b;font-weight:600;color:#fff}
.new-chat-btn{margin:12px;padding:10px 16px;background:#38BDF8;color:#0B1F3A;border:none;border-radius:8px;font-weight:600;cursor:pointer;transition:background .2s}
.new-chat-btn:hover{background:#0EA5E9}
.chat-list{flex:1;overflow-y:auto;padding:0 8px}
.chat-item{width:100%;padding:8px 12px;margin-bottom:4px;border-radius:8px;text-align:left;background:none;border:none;color:#94a3b8;cursor:pointer;font-size:13px;transition:all .2s}
.chat-item:hover{background:#1e293b;color:#fff}
.chat-item.active{background:#1e293b;color:#fff}
.main{flex:1;display:flex;flex-direction:column}
.header{height:56px;border-bottom:1px solid #1e293b;display:flex;align-items:center;justify-content:space-between;padding:0 16px}
.header-title{font-weight:600;color:#fff}
.model-select{background:#1e293b;color:#fff;border:1px solid #334155;border-radius:6px;padding:6px 12px;font-size:13px}
.messages{flex:1;overflow-y:auto;padding:20px;display:flex;flex-direction:column;gap:12px}
.welcome{display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;text-align:center}
.welcome-icon{width:64px;height:64px;background:#38BDF8;border-radius:16px;display:flex;align-items:center;justify-content:center;font-size:28px;font-weight:700;color:#0B1F3A;margin-bottom:16px}
.welcome h2{font-size:20px;margin-bottom:8px;color:#fff}
.welcome p{color:#94a3b8;max-width:400px}
.message{max-width:80%;padding:12px 16px;border-radius:14px;font-size:14px;line-height:1.6;word-wrap:break-word;overflow-wrap:break-word;white-space:pre-wrap}
.message.user{align-self:flex-end;background:#38BDF8;color:#0B1F3A;max-width:75%;min-width:80px;border-bottom-right-radius:4px}
.message.assistant{align-self:flex-start;background:#1e293b;color:#e2e8f0;max-width:85%;border-bottom-left-radius:4px}
.msg-row{display:flex;gap:10px;max-width:3xl;margin:0 auto;width:100%}
.msg-row.user{flex-direction:row-reverse}
.msg-avatar{width:28px;height:28px;border-radius:50%;display:flex;align-items:center;justify-content:center;flex-shrink:0;font-size:12px;font-weight:700}
.msg-avatar.user{background:#38BDF8;color:#0B1F3A}
.msg-avatar.assistant{background:#1e293b;color:#94a3b8;border:1px solid #334155}
.msg-meta{font-size:11px;color:#64748b;margin-bottom:3px}
.msg-meta.user{text-align:right}
.input-area{border-top:1px solid #1e293b;padding:16px}
.input-row{display:flex;gap:8px}
.input-row input{flex:1;background:#1e293b;border:1px solid #334155;border-radius:8px;padding:12px 16px;color:#fff;font-size:14px;outline:none}
.input-row input:focus{border-color:#38BDF8}
.input-row button{background:#38BDF8;color:#0B1F3A;border:none;border-radius:8px;padding:12px 20px;font-weight:600;cursor:pointer;transition:background .2s}
.input-row button:hover{background:#0EA5E9}
.input-row button:disabled{opacity:.5;cursor:not-allowed}
.auth-screen{display:flex;align-items:center;justify-content:center;height:100vh;background:#0B1F3A}
.auth-box{width:360px;background:#0f172a;border:1px solid #1e293b;border-radius:12px;padding:32px}
.auth-box h1{text-align:center;margin-bottom:24px;color:#fff}
.auth-box input{width:100%;margin-bottom:12px;padding:12px;background:#1e293b;border:1px solid #334155;border-radius:8px;color:#fff;font-size:14px;outline:none}
.auth-box input:focus{border-color:#38BDF8}
.auth-box button{width:100%;padding:12px;background:#38BDF8;color:#0B1F3A;border:none;border-radius:8px;font-weight:600;cursor:pointer;transition:background .2s}
.auth-box button:hover{background:#0EA5E9}
.auth-box .error{color:#f87171;font-size:13px;margin-bottom:12px}
.footer{padding:12px;border-top:1px solid #1e293b;font-size:11px;color:#475569}
.new-chat-btn svg,.chat-item svg,.footer svg{display:inline-block;vertical-align:middle;margin-right:4px}
#send-btn svg,#stop-btn svg{display:inline-block;vertical-align:middle;margin-right:4px}
</style>
</head>
<body>
<div id="app"></div>
<script>
const API = "/api";
let currentUser = null;
let conversations = [];
let activeId = null;
let models = [];
let selectedModel = "";
let streaming = false;
let abortController = null;

async function api(method, path, body) {
  const opts = { method, credentials: "include", headers: {} };
  if (body) { opts.headers["Content-Type"] = "application/json"; opts.body = JSON.stringify(body); }
  const r = await fetch(API + path, opts);
  if (r.status === 401) throw new Error("Not authenticated");
  if (!r.ok) { const e = await r.json().catch(() => ({})); throw new Error(e.error || `HTTP ${r.status}`); }
  if (r.status === 204) return null;
  return r.json();
}

async function setupRequired() { const r = await fetch(API + "/auth/setup-required", { credentials: "include" }); return (await r.json()).required; }
async function setup(data) { return api("POST", "/auth/setup", data); }
async function login(data) { return api("POST", "/auth/login", data); }
async function getMe() { try { return await api("GET", "/auth/me"); } catch { return null; } }
async function logout() { await api("POST", "/auth/logout", {}); currentUser = null; showLogin(); }
async function listModels() { try { const r = await fetch(API + "/models", { credentials: "include" }); return (await r.json()).models || []; } catch { return []; } }

function uid() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 8); }
function loadConversations() { const raw = localStorage.getItem("convos"); return raw ? JSON.parse(raw) : []; }
function saveConversations() { localStorage.setItem("convos", JSON.stringify(conversations)); }

function renderAuthScreen(isSetup) {
  const app = document.getElementById("app");
  app.innerHTML = `
    <div class="auth-screen">
      <div class="auth-box">
        <h1>${isSetup ? "First-Time Setup" : "AI for You"}</h1>
        <div id="auth-error"></div>
        <input id="auth-user" placeholder="Username" value="${isSetup ? 'admin' : ''}">
        <input id="auth-pass" type="password" placeholder="Password (min 8 chars)">
        ${isSetup ? '<input id="auth-name" placeholder="Display name" value="Administrator">' : ''}
        <button onclick="handleAuth(${isSetup})">${isSetup ? "Create Admin" : "Sign In"}</button>
      </div>
    </div>`;
}

async function handleAuth(isSetup) {
  const user = document.getElementById("auth-user").value;
  const pass = document.getElementById("auth-pass").value;
  const name = isSetup ? (document.getElementById("auth-name")?.value || user) : "";
  const errDiv = document.getElementById("auth-error");
  try {
    currentUser = isSetup ? await setup({ username: user, password: pass, displayName: name }) : await login({ username: user, password: pass });
    initApp();
  } catch (e) { errDiv.innerHTML = `<div class="error">${e.message}</div>`; }
}

function initApp() {
  conversations = loadConversations();
  if (!conversations.length) { const c = { id: uid(), title: "New chat", model: "", messages: [], createdAt: Date.now(), updatedAt: Date.now() }; conversations.push(c); }
  activeId = conversations[0].id;
  renderApp();
  listModels().then(m => { models = m; if (m.length && !selectedModel) selectedModel = m[0].name; renderHeader(); });
}

const ICON = {
  plus: `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>`,
  message: `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>`,
  user: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>`,
  bot: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><rect x="3" y="11" width="18" height="10" rx="2"/><circle cx="12" cy="5" r="2"/><path d="M12 7v4"/><line x1="8" y1="16" x2="8" y2="16"/><line x1="16" y1="16" x2="16" y2="16"/></svg>`,
  settings: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>`,
  trash: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>`,
  edit: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>`,
  logout: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>`,
  stop: `<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="6" width="12" height="12" rx="2"/></svg>`,
  send: `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>`,
};

function renderApp() {
  const app = document.getElementById("app");
  app.innerHTML = `
    <div class="sidebar">
      <div class="sidebar-header">AI for You</div>
      <button class="new-chat-btn" onclick="newChat()">${ICON.plus} New Chat</button>
      <div class="chat-list" id="chat-list"></div>
      <div class="footer">
        <span style="display:flex;align-items:center;gap:6px">${ICON.user} ${currentUser?.displayName || ""} ${currentUser?.isAdmin ? "(Admin)" : ""}</span>
        <span style="display:flex;align-items:center;gap:8px;margin-top:6px">
          <span style="cursor:pointer;opacity:.6;transition:opacity .2s" onmouseover="this.style.opacity=1" onmouseout="this.style.opacity=.6" onclick="logout()" title="Sign out">${ICON.logout}</span>
        </span>
      </div>
    </div>
    <div class="main">
      <div class="header">
        <span class="header-title">AI Assistant</span>
        <select class="model-select" id="model-select" onchange="selectedModel=this.value">
          ${models.map(m => `<option value="${m.name}" ${m.name === selectedModel ? "selected" : ""}>${m.name}</option>`).join("")}
          ${!models.length ? '<option>No models</option>' : ''}
        </select>
      </div>
      <div class="messages" id="messages"></div>
      <div class="input-area">
        <div class="input-row">
          <input id="msg-input" placeholder="Ask anything..." onkeydown="if(event.key==='Enter'&&!event.shiftKey)sendMessage()">
          <button onclick="sendMessage()" id="send-btn">${ICON.send} Send</button>
          <button onclick="stopStreaming()" id="stop-btn" style="display:none;background:#ef4444">${ICON.stop} Stop</button>
        </div>
      </div>
    </div>`;
  renderChatList();
  renderMessages();
}

function renderChatList() {
  const list = document.getElementById("chat-list");
  if (!list) return;
  list.innerHTML = conversations.map(c =>
    `<button class="chat-item ${c.id === activeId ? 'active' : ''}" onclick="switchChat('${c.id}')">${ICON.message} ${c.title}</button>`
  ).join("");
}

function renderHeader() {
  const sel = document.getElementById("model-select");
  if (!sel) return;
  sel.innerHTML = models.map(m => `<option value="${m.name}" ${m.name === selectedModel ? "selected" : ""}>${m.name}</option>`).join("") + (!models.length ? '<option>No models</option>' : '');
}

function renderMessages() {
  const msgs = document.getElementById("messages");
  if (!msgs) return;
  const conv = conversations.find(c => c.id === activeId);
  if (!conv || !conv.messages.length) {
    msgs.innerHTML = `
      <div class="welcome">
        <div class="welcome-icon">${ICON.bot}</div>
        <h2>AI Assistant</h2>
        <p>Secure, private AI running on your own hardware. Nothing leaves your network.</p>
      </div>`;
    return;
  }
  msgs.innerHTML = conv.messages.map(m => {
    const isUser = m.role === "user";
    const isAssistant = m.role === "assistant";
    const isStreamingThis = streaming && isAssistant && m === conv.messages[conv.messages.length - 1];
    const avatar = isUser ? ICON.user : ICON.bot;
    const avatarClass = isUser ? "user" : "assistant";
    const name = isUser ? "You" : "AI Assistant";
    const content = escapeHtml(m.content) || (isStreamingThis ? "<span style='opacity:.5'>Thinking...</span>" : "");
    return `<div class="msg-row ${m.role}">
      <div class="msg-avatar ${avatarClass}">${avatar}</div>
      <div style="flex:1;min-width:0">
        <div class="msg-meta ${m.role}">${name}</div>
        <div class="message ${m.role}">${content}</div>
      </div>
    </div>`;
  }).join("");
  msgs.scrollTop = msgs.scrollHeight;
}

function stopStreaming() {
  if (abortController) { abortController.abort(); abortController = null; }
  streaming = false;
  const sendBtn = document.getElementById("send-btn");
  const stopBtn = document.getElementById("stop-btn");
  if (sendBtn) sendBtn.style.display = "";
  if (stopBtn) stopBtn.style.display = "none";
  saveConversations(); renderMessages();
}

function escapeHtml(t) { const d = document.createElement("div"); d.textContent = t; return d.innerHTML; }

function switchChat(id) { activeId = id; renderChatList(); renderMessages(); }

function newChat() {
  const c = { id: uid(), title: "New chat", model: selectedModel, messages: [], createdAt: Date.now(), updatedAt: Date.now() };
  conversations.unshift(c); activeId = c.id;
  saveConversations(); renderApp();
}

async function sendMessage() {
  const input = document.getElementById("msg-input");
  const text = input.value.trim();
  if (!text || !selectedModel || streaming) return;
  input.value = "";
  streaming = true;
  const sendBtn = document.getElementById("send-btn");
  const stopBtn = document.getElementById("stop-btn");
  if (sendBtn) sendBtn.style.display = "none";
  if (stopBtn) stopBtn.style.display = "";
  if (stopBtn) stopBtn.disabled = false;

  const conv = conversations.find(c => c.id === activeId);
  const userMsg = { id: uid(), role: "user", content: text, createdAt: Date.now() };
  conv.messages.push(userMsg);
  if (conv.title === "New chat") conv.title = text.slice(0, 40) + (text.length > 40 ? "..." : "");
  conv.updatedAt = Date.now();
  saveConversations();
  renderMessages(); renderChatList();

  const assistantMsg = { id: uid(), role: "assistant", content: "", createdAt: Date.now() };
  conv.messages.push(assistantMsg);
  renderMessages();

  abortController = new AbortController();
  try {
    const r = await fetch(API + "/chat", {
      method: "POST", credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: selectedModel, messages: conv.messages.map(m => ({ role: m.role, content: m.content })) }),
      signal: abortController.signal,
    });
    if (!r.ok || !r.body) throw new Error("Server error");
    const reader = r.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let nl;
      while ((nl = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);
        if (!line.trim()) continue;
        try {
          const chunk = JSON.parse(line);
          const token = chunk.message?.content;
          if (token) { assistantMsg.content += token; renderMessages(); }
        } catch {}
      }
    }
  } catch (e) { assistantMsg.content += "\n[Error: " + e.message + "]"; renderMessages(); }
  finally { streaming = false; const sendBtn = document.getElementById("send-btn"); const stopBtn = document.getElementById("stop-btn"); if (sendBtn) { sendBtn.style.display = ""; sendBtn.disabled = false; } if (stopBtn) stopBtn.style.display = "none"; saveConversations(); renderChatList(); }
}

async function boot() {
  const req = await setupRequired();
  if (req) { renderAuthScreen(true); return; }
  currentUser = await getMe();
  if (!currentUser) { renderAuthScreen(false); return; }
  initApp();
}

boot();
</script>
</body>
</html>
HTML

# ── Step 9: Dockerfile ──
cat > "$DEPLOY_DIR/src/Dockerfile" <<'DOCKER'
FROM node:24-bookworm-slim
WORKDIR /app
COPY package.json .
RUN npm install express cors express-session
COPY . .
ENV FRONTEND_DIST=/app/public PORT=8080
EXPOSE 8080
CMD ["node", "server.js"]
DOCKER

cat > "$DEPLOY_DIR/src/package.json" <<'JSON'
{"dependencies":{"express":"^5","cors":"^2","express-session":"^1"}}
JSON

# ── Step 10: Build & launch ──
status "Building..."
cd "$DEPLOY_DIR/src" && docker build -t abc-ai-panel:latest .
ok "Image built"

status "Starting stack..."
cd "$DEPLOY_DIR/docker" && docker compose up -d
ok "Stack started"

# ── Step 11: Staging SSL ──
if [ -n "$EMAIL" ]; then
  status "SSL staging..."
  sleep 5
  docker stop ai-nginx
  if docker run --rm \
    -v "$DEPLOY_DIR/certbot-conf:/etc/letsencrypt" \
    -v "$DEPLOY_DIR/certbot-www:/var/www/certbot" \
    -p 80:80 \
    certbot/certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN"; then
    ok "SSL ready"
    cat > "$DEPLOY_DIR/nginx/ai.conf" <<EOF
server {
    listen 80; server_name $DOMAIN;
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl; http2 on; server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
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
    docker start ai-nginx || docker restart ai-nginx
    ok "HTTPS active — green lock in browser"
  else
    docker start ai-nginx || docker restart ai-nginx
    warn "SSL failed — using HTTP only (set a real EMAIL for SSL)"
  fi
else
  warn "EMAIL not set — skipping SSL (HTTP only)"
fi

# ── Step 12: Pull models ──
status "Waiting for Ollama..."
for i in $(seq 1 60); do
  docker exec ai-ollama ollama list >/dev/null 2>&1 && { ok "Ollama ready"; break; }
  sleep 5
  [ "$i" -eq 60 ] && warn "Ollama timeout"
done

for model in llama3.2 qwen2.5:7b mistral:7b; do
  status "Pulling $model..."
  docker exec ai-ollama ollama pull "$model" || warn "Failed: $model"
done
ok "Models done"

# ── Summary ──
cat <<SUMMARY

${GREEN}============================================================${RESET}
${GREEN}  AI for You — Installed${RESET}
${GREEN}============================================================${RESET}
  URL:      http://$DOMAIN  (or https:// if SSL worked)
  Install:  curl -fsSL http://install.$DOMAIN/install.sh | sh
  Dir:      $DEPLOY_DIR
  .env:     $DEPLOY_DIR/.env
  Logs:     docker logs ai-panel

  Visit the URL and create your admin account.

  ${BOLD}Admin password:${RESET} $ADMIN_PASSWORD
${GREEN}============================================================${RESET}

SUMMARY
