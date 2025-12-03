#!/usr/bin/env bash
set -euo pipefail

# Marzban Emergency Installer v1
# Usage: sudo ./installer.sh

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo $0"
  exit 1
fi

echo "=== Marzban Emergency Installer (v1) ==="
sleep 0.6

# -- Configurable paths --
BASE_DIR="/opt/marzban"
EMG_DIR="$BASE_DIR/marzban-emergency"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
HTML_FILE="/var/lib/marzban/templates/subscription/index.html"
STORAGE_DIR="/var/lib/marzban"

# default ports
EMG_PORT=5010
EMG_SERVICE_NAME="marzban-emergency"

# ---------- 1) Install prerequisites ----------
echo "[1/10] Installing prerequisites (nginx, docker, docker-compose-plugin, curl, jq)..."
apt-get update -y
apt-get install -y nginx curl jq apt-transport-https ca-certificates gnupg lsb-release

# Install docker if missing
if ! command -v docker >/dev/null 2>&1; then
  echo "[1] Installing docker..."
  apt-get install -y docker.io
fi

# Ensure docker compose plugin (or do-nothing if already)
if ! docker compose version >/dev/null 2>&1; then
  echo "[1] Installing docker compose plugin..."
  apt-get install -y docker-compose-plugin || true
fi

systemctl enable --now nginx || true
systemctl enable --now docker || true

# ---------- 2) Ask user for parameters ----------
echo
echo "=== Configuration ==="
read -p "1) Domain to configure for nginx (e.g. rebecca.tbznet.top): " PANEL_DOMAIN
read -p "2) Marzban panel port on localhost (e.g. 4178 or 8000): " PANEL_PORT
read -p "3) Admin username for Marzban panel: " ADMIN_USER
read -sp "4) Admin password for Marzban panel: " ADMIN_PASS
echo
read -p "5) Path to SSL fullchain.pem (for nginx): " SSL_FULLCHAIN
read -p "6) Path to SSL privkey.pem (for nginx): " SSL_PRIVKEY

# Validate paths
if [ ! -f "$SSL_FULLCHAIN" ]; then
  echo "ERROR: SSL fullchain not found at $SSL_FULLCHAIN"
  exit 1
fi
if [ ! -f "$SSL_PRIVKEY" ]; then
  echo "ERROR: SSL privkey not found at $SSL_PRIVKEY"
  exit 1
fi

# Ensure base dir exists
mkdir -p "$BASE_DIR"
mkdir -p "$STORAGE_DIR"

# ---------- 3) Create marzban-emergency dir and Dockerfile ----------
echo "[2/10] Creating $EMG_DIR and Dockerfile..."
mkdir -p "$EMG_DIR"
chown -R root:root "$EMG_DIR"

cat > "$EMG_DIR/Dockerfile" <<'DOCKERFILE'
FROM python:3.10-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn requests python-dotenv

COPY main.py /app/main.py
COPY .env /app/.env

EXPOSE 5010

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5010"]
DOCKERFILE

# ---------- 4) Write main.py ----------
echo "[3/10] Writing main.py..."
cat > "$EMG_DIR/main.py" <<'PY'
# main.py (FINAL VERSION)
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
import os, json, time, requests, threading, urllib3
from pydantic import BaseModel
from typing import Optional

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

STORAGE_PATH = "/var/lib/marzban/emergency_flags.json"
STORAGE_DIR = os.path.dirname(STORAGE_PATH)
MARZBAN_BASE = os.environ.get("MARZBAN_BASE_URL", "")
MARZBAN_ADMIN_TOKEN = os.environ.get("MARZBAN_ADMIN_TOKEN", "")

app = FastAPI(title="Marzban Emergency Service")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
_store_lock = threading.Lock()

def _ensure_storage_dir():
    try:
        if not os.path.isdir(STORAGE_DIR):
            os.makedirs(STORAGE_DIR, exist_ok=True)
    except:
        pass

def load_store() -> dict:
    _ensure_storage_dir()
    try:
        with open(STORAGE_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except Exception:
        return {}

def save_store(d: dict):
    _ensure_storage_dir()
    tmp = STORAGE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    os.replace(tmp, STORAGE_PATH)

def marz_get_user(username: str) -> dict:
    url = f"{MARZBAN_BASE}/api/user/{username}"
    headers = {"Authorization": f"Bearer {MARZBAN_ADMIN_TOKEN}"} if MARZBAN_ADMIN_TOKEN else {}
    r = requests.get(url, headers=headers, verify=False, timeout=10)
    if r.status_code != 200:
        raise Exception(f"Marzban GET failed: {r.status_code} {r.text}")
    return r.json()

def marz_update_user(username: str, payload: dict):
    url = f"{MARZBAN_BASE}/api/user/{username}"
    headers = {"Authorization": f"Bearer {MARZBAN_ADMIN_TOKEN}", "Content-Type": "application/json"} if MARZBAN_ADMIN_TOKEN else {"Content-Type": "application/json"}
    r = requests.put(url, headers=headers, json=payload, verify=False, timeout=10)
    return r

def _to_int_safe(v: Optional[object]) -> Optional[int]:
    if v is None:
        return None
    try:
        return int(v)
    except:
        try:
            return int(float(v))
        except:
            return None

class GrantRequest(BaseModel):
    add_bytes: int
    add_seconds: int

@app.get("/emergency/{username}")
def check(username: str):
    store = load_store()
    rec = store.get(username)
    if not rec:
        return {"username": username, "used": False}
    try:
        user = marz_get_user(username)
    except Exception as e:
        return {"username": username, "used": True, "error": str(e)}
    cur_limit = _to_int_safe(user.get("data_limit"))
    cur_expire = _to_int_safe(user.get("expire"))
    saved_limit = _to_int_safe(rec.get("saved_data_limit"))
    saved_expire = _to_int_safe(rec.get("saved_expire"))
    renewed = False
    if saved_limit is not None and cur_limit is not None and cur_limit > saved_limit:
        renewed = True
    if saved_expire is not None and cur_expire is not None and cur_expire > saved_expire:
        renewed = True
    if renewed:
        with _store_lock:
            store.pop(username, None)
            save_store(store)
        return {"username": username, "used": False, "renewed": True}
    return {"username": username, "used": bool(rec.get("used", True)), "granted_at": rec.get("granted_at")}

@app.post("/emergency/{username}/grant")
def grant(username: str, body: GrantRequest, request: Request):
    # basic anti-abuse (light): require referer contains /sub/ or same origin
    referer = request.headers.get("referer") or ""
    origin = request.headers.get("origin") or ""
    if referer == "" and origin == "":
        raise HTTPException(status_code=403, detail="Direct API access blocked")
    # payload rate-limit / double-click prevention using simple store file (not perfect)
    with _store_lock:
        store = load_store()
        if store.get(username, {}).get("used"):
            raise HTTPException(status_code=400, detail="Emergency already used")
    try:
        user = marz_get_user(username)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch user from Marzban: {e}")
    current_limit = _to_int_safe(user.get("data_limit")) or 0
    current_expire = _to_int_safe(user.get("expire")) or 0
    now = int(time.time())
    base_expire = current_expire if current_expire > now else now
    new_expire = base_expire + int(body.add_seconds)
    new_limit = current_limit + int(body.add_bytes)
    payload = {"data_limit": new_limit, "expire": new_expire}
    r = marz_update_user(username, payload)
    if r.status_code not in (200, 204):
        raise HTTPException(status_code=500, detail=f"Marzban update failed: {r.status_code} {r.text}")
    record = {
        "used": True,
        "granted_at": now,
        "saved_data_limit": current_limit,
        "saved_expire": current_expire,
        "granted_data_limit": new_limit,
        "granted_expire": new_expire
    }
    with _store_lock:
        store = load_store()
        store[username] = record
        save_store(store)
    return {"ok": True, "username": username, "record": record}
PY

# ---------- 5) Create .env template (will be replaced with token) ----------
echo "[4/10] Preparing .env template..."
cat > "$EMG_DIR/.env" <<EOF
MARZBAN_BASE_URL=https://127.0.0.1:${PANEL_PORT}
MARZBAN_ADMIN_TOKEN=
EOF
chmod 600 "$EMG_DIR/.env"

# ---------- 6) Request admin token from Marzban panel ----------
echo "[5/10] Requesting admin token from Marzban panel..."
TOKEN_API="https://127.0.0.1:${PANEL_PORT}/api/admin/token"

# try to fetch token (jq preferred)
TOKEN_JSON=""
if command -v jq >/dev/null 2>&1; then
  TOKEN_JSON=$(curl -sk -X POST "$TOKEN_API" -d "username=${ADMIN_USER}" -d "password=${ADMIN_PASS}" -d "grant_type=password" || true)
  ADMIN_TOKEN=$(echo "$TOKEN_JSON" | jq -r '.access_token // .token // .access // empty')
else
  TOKEN_JSON=$(curl -sk -X POST "$TOKEN_API" -d "username=${ADMIN_USER}" -d "password=${ADMIN_PASS}" -d "grant_type=password" || true)
  ADMIN_TOKEN=$(echo "$TOKEN_JSON" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi

if [ -z "${ADMIN_TOKEN:-}" ]; then
  echo "ERROR: Failed to obtain admin token. Response was:"
  echo "$TOKEN_JSON"
  exit 1
fi

echo "[6/10] Got admin token."

cat > "$EMG_DIR/.env" <<EOF
MARZBAN_BASE_URL=https://127.0.0.1:${PANEL_PORT}
MARZBAN_ADMIN_TOKEN=${ADMIN_TOKEN}
EOF
chmod 600 "$EMG_DIR/.env"

# ---------- 7) Append service to docker-compose.yml (if not present) ----------
echo "[7/10] Ensuring service is in $COMPOSE_FILE (backup first)..."
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "ERROR: docker-compose.yml not found at $COMPOSE_FILE"
  exit 1
fi
cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak.$(date +%s)"

# simple idempotent append: check for service name
if ! grep -q "^[[:space:]]*${EMG_SERVICE_NAME}:" "$COMPOSE_FILE"; then
  cat >> "$COMPOSE_FILE" <<EOF

  ${EMG_SERVICE_NAME}:
    build: ./marzban-emergency
    restart: always
    env_file: ./marzban-emergency/.env
    network_mode: host
    volumes:
      - /var/lib/marzban:/var/lib/marzban
EOF
  echo "Service appended to $COMPOSE_FILE"
else
  echo "Service already present — skipping append."
fi

# ---------- 8) Create nginx config ----------
echo "[8/10] Creating nginx config at /etc/nginx/conf.d/emergency.conf (backup if exists)..."
NGINX_CONF="/etc/nginx/conf.d/emergency.conf"
if [ -f "$NGINX_CONF" ]; then
  cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%s)"
fi

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${PANEL_DOMAIN};

    ssl_certificate     ${SSL_FULLCHAIN};
    ssl_certificate_key ${SSL_PRIVKEY};

    client_max_body_size 50M;
    proxy_read_timeout   300;
    proxy_connect_timeout 300;
    proxy_send_timeout   300;

    # Reverse proxy → Marzban panel (HTTPS backend)
    location / {
        proxy_pass https://127.0.0.1:${PANEL_PORT};
        proxy_ssl_verify off;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    # Emergency service → FastAPI
    location /emergency/ {
        proxy_pass http://127.0.0.1:${EMG_PORT}/emergency/;
        
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

echo "Testing nginx configuration..."
if ! nginx -t; then
  echo "ERROR: nginx config test failed. Check $NGINX_CONF and nginx logs."
  exit 1
fi

echo "Reloading nginx..."
systemctl reload nginx || true

# ---------- 9) CREATE FULL index.html FILE ----------
echo "[9/10] Creating FULL index.html file (no injection)..."

mkdir -p "$(dirname "$HTML_FILE")"

cp "$HTML_FILE" "${HTML_FILE}.bak.$(date +%s)" 2>/dev/null || true

cat > "$HTML_FILE" <<'EOF'
<!doctype html>
<html lang="fa" dir="rtl" data-bs-theme="dark">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ناحیه کاربری</title>
  <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><path d='M8 3.5a.5.5 0 0 0-1 0V9a.5.5 0 0 0 .252.434l3.5 2a.5.5 0 0 0 .496-.868L8 8.71z'/><path d='M8 16A8 8 0 1 0 8 0a8 8 0 0 0 0 16m7-8A7 7 0 1 1 1 8a7 7 0 0 1 14 0'/></svg>">

  <link rel="preload" href="https://fonts.googleapis.com/css2?family=Vazirmatn:wght@400;500&display=swap" as="style">
  <link rel="preload" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.rtl.min.css" as="style">
  <link rel="preload" href="https://unpkg.com/alpinejs@3.13.7/dist/cdn.min.js" as="script">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Vazirmatn:wght@400;500&display=swap">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.rtl.min.css">
  
  <style>
    :root {
      --bs-body-font-family: "Vazirmatn", system-ui, -apple-system, sans-serif;
      --bs-body-bg: #000000;
      --my-gray: #18181b;
      --my-dark-gray: #27272a;
      --my-alpha-gray: #3f3f46;
      --my-heading: #ffffff;
      --my-content: #d4d4d8;
      --btn-text-color: #ffffff;
      --btn-hover-bg: #27272a;
      --backdrop-blur: blur(10px);
      --username-icon-color: #006FEE;
      --active-status-icon-color: #17c964;
      --disabled-status-icon-color: #ff2d2d;
      --duration-icon-color: #f5a524;
      --traffic-icon-color: #9253d2;
      --sun-icon-color: #f5a524;
      --moon-icon-color: #9253d2;
      --lang-icon-color: #006FEE;
      --windows-icon-color: #006FEE;
      --android-icon-color: #17c964;
      --apple-icon-color: currentColor;
      --success-feedback-color: #17c964;
    }

    :root[data-bs-theme="light"] {
      --bs-body-bg: #ffffff;
      --my-gray: #f4f4f5;
      --my-dark-gray: #e4e4e7;
      --my-alpha-gray: #d4d4d8;
      --my-heading: #000000;
      --my-content: #3f3f46;
      --btn-text-color: #1c2938;
      --btn-hover-bg: #e4e4e7;
      --backdrop-blur: blur(12px);
    }

    .my-block svg use[href="#person-circle"] {
      color: var(--username-icon-color);
    }
    
    .my-block svg use[href="#check-circle"] {
      color: var(--active-status-icon-color);
    }
    
    .my-block svg use[href="#x-circle"] {
      color: var(--disabled-status-icon-color);
    }
    
    .my-block svg use[href="#clock"] {
      color: var(--duration-icon-color);
    }
    
    .my-block svg use[href="#arrow-down-circle"] {
      color: var(--traffic-icon-color);
    }
    
    .theme-toggle svg use[href="#sun"] {
      color: var(--sun-icon-color);
    }
    
    .theme-toggle svg use[href="#moon"] {
      color: var(--moon-icon-color);
    }
    
    .lang-toggle svg use[href="#translate"] {
      color: var(--lang-icon-color);
    }
    
    .config-link-name svg use[href="#microsoft"] {
      color: var(--windows-icon-color);
    }
    
    .config-link-name svg use[href="#android"] {
      color: var(--android-icon-color);
    }

    [x-cloak] { display: none !important; }

    body {
      background-color: var(--bs-body-bg);
      font-family: var(--bs-body-font-family);
    }

    .my-container {
      max-width: 1024px;
      padding: clamp(50px, 5vw, 75px) clamp(15px, 2.5vw, 25px);
      margin: 0 auto;
    }

    .page-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 2rem;
    }

    .header-title-section {
      display: flex;
      align-items: center;
    }

    .header-buttons-section {
      display: flex;
      align-items: center;
      gap: 1rem;
    }

    .user-avatar {
      width: 49.6px;
      height: 49.6px;
      border-radius: 50%;
      overflow: hidden;
      background-color: var(--my-gray);
      border: none;
      flex-shrink: 0;
      margin-left: 1rem;
    }

    [dir="ltr"] .user-avatar {
      margin-left: 0;
      margin-right: 1rem;
    }

    .user-avatar img {
      width: 100%;
      height: 100%;
      object-fit: cover;
    }

    .user-avatar-placeholder {
      width: 100%;
      height: 100%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 1.5rem;
      font-weight: 500;
      color: var(--my-content);
    }

    .theme-toggle, .lang-toggle {
      display: flex;
      align-items: center;
      justify-content: center;
      width: 49.6px;
      height: 49.6px;
      border-radius: 50px;
      background-color: var(--my-gray);
      color: var(--my-heading);
      border: none;
      padding: 0;
    }
    
    .theme-toggle:hover, .lang-toggle:hover {
      background-color: var(--my-dark-gray);
    }
    
    .theme-toggle:focus, .lang-toggle:focus {
      outline: none !important;
      box-shadow: none !important;
    }

    .theme-toggle svg, .lang-toggle svg {
      width: 20px;
      height: 20px;
      fill: currentColor;
    }

    .my-text-heading { color: var(--my-heading); }
    .my-text-content { color: var(--my-content); }

    .my-block,
    .my-block-big {
      border-radius: 0.875rem;
      background-color: var(--my-gray);
      padding: 1.5rem;
      height: 100%;
      border: none;
    }

    .my-block-big {
      padding: 1.5rem;
    }

    .traffic-value {
      font-family: inherit;
      direction: ltr;
      display: inline-block;
      text-align: left;
      width: 100%;
    }

    .bi {
      fill: currentColor;
      width: 20px;
      height: 20px;
    }

    [dir="rtl"] .my-block .bi {
      margin-left: 0.5rem;
      margin-right: 0;
      margin-bottom: 0.15rem;
    }

    [dir="ltr"] .my-block .bi {
      margin-right: 0.5rem;
      margin-left: 0;
      margin-bottom: 0.25rem;
    }

    [dir="ltr"] h3.my-text-heading .bi {
      transform: translateY(-.2rem);
    }

    [dir="rtl"] h3.my-text-heading .bi {
      transform: translateY(-.075rem);
    }

    .connection-buttons {
      display: flex;
      flex-direction: row;
      flex-wrap: nowrap;
      gap: 1rem;
      margin-bottom: 2.5rem;
    }

    .my-btn-outline {
      --bs-btn-color: var(--btn-text-color);
      border: none;
      --bs-btn-hover-color: var(--btn-text-color);
      --bs-btn-hover-bg: var(--btn-hover-bg);
      --bs-btn-active-color: var(--btn-text-color);
      --bs-btn-active-bg: var(--btn-hover-bg);
      --bs-border-radius: 0.875rem;
      width: 100%;
      padding: 0.75rem;
      background-color: var(--my-gray);
    }

    [dir="ltr"] .my-btn-outline span {
      vertical-align: -0.1em;    
    }

    [dir="ltr"] .config-link-copy-btn span {
      transform: translateY(0.1rem);
    }

    .modal.my-modal {
      --bs-modal-bg: var(--my-gray);
      --bs-modal-border-radius: 0.875rem;
      --bs-modal-header-padding: 2.5rem 1.5rem 0;
      --bs-modal-header-border-width: 0;
      backdrop-filter: var(--backdrop-blur);
      border: none;
    }

    .modal-body p.my-text-content {
      margin-bottom: 1rem;
      padding: 0 0.5rem;
    }

    .config-link {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 1rem;
      margin-bottom: 0.75rem;
      background-color: var(--my-dark-gray);
      border-radius: 0.875rem;
    }
    
    .config-link-name {
      font-weight: 500;
      color: var(--my-heading);
      flex-grow: 1;
      padding: 0 0.5rem;
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }

    .config-link-buttons {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      flex-shrink: 0;
    }

    .config-link-qr-btn {
      width: 40px;
      height: 40px;
      padding: 0;
      border-radius: 0.875rem;
      background-color: var(--bs-body-bg);
      color: var(--btn-text-color);
      display: flex;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
      border: none;
    }

    .config-link-qr-btn svg {
      width: 20px;
      height: 20px;
    }

    .config-link-qr-btn:hover {
      background-color: var(--my-gray);
    }

    .config-link-copy-btn,
    .download-button,
    .settings-button {
      height: 40px;
      box-sizing: border-box;
      overflow: hidden;
      white-space: nowrap;
      transition: background-color 0.2s ease;
      min-width: 100px;
      padding: 0.5rem 1rem;
      border-radius: 0.875rem;
      background-color: var(--bs-body-bg);
      color: var(--btn-text-color);
      border: none;
      flex-shrink: 0;
      text-align: center;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 0.5rem;
      text-decoration: none;
    }

    .config-link-copy-btn:hover,
    .download-button:hover,
    .settings-button:hover {
      background-color: var(--my-gray);
      color: var(--btn-text-color);
    }

    .config-link-copy-btn.copied,
    .download-button.copied,
    .settings-button.copied {
      background-color: var(--success-feedback-color) !important;
      color: white !important;
    }

    .download-buttons {
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
    }

    [dir="ltr"] .download-button span,
     .settings-button span,
     .config-link-name span {
      transform: translateY(0.1rem);
    }

    [dir="rtl"] .settings-button.copied span {
      transform: translateY(-0.1rem);
    }

    .equal-height-container {
      display: flex;
      flex-direction: column;
      height: 100%;
    }

    .equal-height-container .my-block-big {
      flex: 1;
    }

    .my-step-counter {
      display: block;
      color: var(--my-heading);
      font-weight: 500;
      font-size: 2.5rem;
      user-select: none;
      text-align: right;
    }

    [dir="ltr"] .my-step-counter {
      text-align: left;
    }

    .my-step-counter::after {
      content: counter(step-counter);
      counter-increment: step-counter;
    }

    .my-tab-pane {
      counter-reset: step-counter;
    }

    .qr-modal {
      --bs-modal-width: min(350px, 90%);
      backdrop-filter: var(--backdrop-blur);
    }

    .qr-modal .modal-dialog {
      width: 350px;
      margin: 1rem auto;
    }

    .qr-modal .modal-content {
      background-color: var(--my-gray);
      border-radius: 0.875rem;
      padding: 1rem 1rem 1.5rem;
      border: none;
    }

    .qr-modal .modal-header {
      border-bottom: none;
      padding: 1rem;
      position: relative;
      display: flex;
      align-items: center;
      gap: 1rem;
    }

    .qr-modal .modal-header .my-text-heading {
      font-size: 1.1rem;
      margin: 0;
      text-align: right;
      flex-grow: 1;
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      padding-inline-end: 1rem;
    }

    [dir="ltr"] .qr-modal .modal-header .my-text-heading {
      text-align: left;
      padding-inline-end: 0;
      padding-inline-start: 0;
    }

    .qr-modal .modal-body {
      padding: 0;
      display: flex;
      flex-direction: column;
      align-items: center;
    }

    .qr-modal #qr-canvas {
      background-color: white;
      padding: 1rem;
      border-radius: 0.875rem;
      margin-bottom: 0.5rem;
      display: flex;
      justify-content: center;
    }

    .qr-modal #qr-canvas img {
      max-width: 100%;
      height: auto;
    }

    .modal-close-btn {
      position: absolute;
      top: 2rem;
      inset-inline-end: 1.5rem;
      min-width: 60px;
      padding: 0.5rem 1.5rem;
      border-radius: 0.875rem;
      background-color: #ff2d2d;
      color: white;
      border: none;
      font-size: 0.875rem;
      border: none;
    }

    .modal-close-btn:hover {
      background-color: #b12121;
    }

    .modal-close-btn:focus, .modal-close-btn:focus-visible {
      outline: none !important;
      box-shadow: none !important;
    }

    .qr-modal .modal-close-btn {
      position: static;
      flex-shrink: 0;
    }

    @media (max-width: 767.98px) {
      .my-container {
        padding: 50px 15px;
      }
      
      .my-block-big {
        padding: 1.25rem 1.5rem 1.5rem;
      }
    }

    @media (max-width: 400px) {
      .qr-modal .modal-dialog {
        width: 90%;
        margin: 1rem auto;
      }
    }
	
/* <!-- -------------- EMERGENCY BUTTON SECTION CSS-------------- --> */

/* در تم تیره */
[data-bs-theme="dark"] .emergency-block {
  background: #18181b !important;
}

/* در تم روشن */
[data-bs-theme="light"] .emergency-block {
  background: #f4f4f5 !important;
}

/* دکمه استفاده‌شده */
.emergency-used-btn {
  min-width: 160px;
  height: 42px;
  border-radius: 0.875rem;
}

/* دکمه اصلی */
.emergency-btn {
  min-width: 160px;
  height: 42px;
  border-radius: 0.875rem;
}

/* بلاک اصلی */
.my-block.emergency-block {
  border-radius: 0.875rem !important;  /* همان مقدار ردیوس بلاک‌ها */
  overflow: hidden;  /* برای جلوگیری از بیرون زدن محتوا از گوشه‌ها */
  align-content: center;
}
/* تنظیمات ارتفاع برای وضعیت محدود */
.height-adjusted {
  height: 90px !important;  /* افزایش ارتفاع کادر برای وضعیت محدود */
}

/* تنظیمات دیگر */
 .emergency-block {
   height: 60px;  /* ارتفاع پیش‌فرض کادر */
}
  
/* <!-- -------------- EMERGENCY BUTTON SECTION CSS END-------------- --> */

  </style>

  <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js" defer></script>
  <script src="https://unpkg.com/alpinejs@3.13.7/dist/cdn.min.js" defer></script>
  
  <script>
    function loadQRCode() {
      if (window.QRCode) return Promise.resolve();
      return new Promise((resolve) => {
        const script = document.createElement('script');
        script.src = 'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js';
        script.onload = resolve;
        document.head.appendChild(script);
      });
    }

    function handleButtonFeedback(button, originalContent, feedbackContent, timeout = 2000) {
      const originalHTML = button.innerHTML;
      button.innerHTML = feedbackContent;
      button.classList.add('copied');
      
      setTimeout(() => {
        button.innerHTML = originalHTML;
        button.classList.remove('copied');
      }, timeout);
    }

    document.addEventListener('alpine:init', () => {
      window.app = {
        darkMode: true,
        currentLang: 'fa',
        avatarUrl: 'https://raw.githubusercontent.com/younex65/public-assets/refs/heads/main/icons/profile2.svg',
        
        translations: {
          fa: {
            subscriptionInfo: 'صفحه کاربری',
            username: 'نام کاربری',
            status: 'وضعیت',
            duration: 'مدت زمان',
            traffic: 'ترافیک',
            anonymous: 'ناشناس',
            active: 'فعال',
            limited: 'محدود',
            expired: 'منقضی‌شده',
            disabled: 'غیرفعال',
            unlimited: 'نامحدود',
            telegramSupport: 'پشتیبانی',
            showConfigs: 'کانفیگ‌ها',
            connectionGuide: 'راهنمای اتصال',
            configLinks: 'لینک‌ کانفیگ ها',
            configLinksDesc: 'برای استفاده از کانفیگ های خود در سایر اپلیکیشن‌ها می‌توانید از لینک‌های زیر استفاده کنید.',
            subscriptionLink: 'لینک اشتراک',
            close: 'خروج',
            copy: 'کپی',
            copied: 'کپی شد',
            vMessConfig: 'کانفیگ VMESS',
            vLessConfig: 'کانفیگ VLESS',
            trojanConfig: 'کانفیگ Trojan',
            shadowsocksConfig: 'کانفیگ Shadowsocks',
            configLink: 'لینک کانفیگ',
            downloadApps: 'دانلود برنامه‌ها',
            downloadAppsDesc: 'با توجه به سیستم عامل خود برنامه مورد نظر را دانلود کنید',
            hiddifyWindows: 'هیدیفای ویندوز',
            hiddifyAndroid: 'هیدیفای اندروید',
            hiddifyApple: 'هیدیفای اپل',
            singboxAndroid: 'سینگ‌ باکس اندروید',
            singboxApple: 'سینگ‌ باکس اپل',
            addSubscription: 'افزودن اشتراک',
            addSubscriptionDesc: 'با توجه به برنامه ای که نصب کرده اید روی دکمه مربوط به آن کلیک کنید',
            hiddifySettings: 'تنظیمات هیدیفای',
            singboxSettings: 'تنظیمات سینگ باکس',
            connectAndUse: 'اتصال و استفاده',
            connectAndUseDesc: 'در برنامه هیدیفای روی دکمه CONNECT و در سینگ باکس روی ENABLE کلیک کنید. پیشنهاد می شود روزانه لینک اشتراک خود را از داخل اپلیکیشن دانلود شده آپدیت کنید',
            qrCode: 'کد QR',
            download: 'دانلود',
            start: 'شروع',
            settings: 'تنظیمات',
            enter: 'ورود'
          },
          en: {
            subscriptionInfo: 'Subscription Page',
            username: 'Username',
            status: 'Status',
            duration: 'Duration',
            traffic: 'Traffic',
            anonymous: 'Anonymous',
            active: 'Active',
            limited: 'Limited',
            expired: 'Expired',
            disabled: 'Disabled',
            unlimited: 'Unlimited',
            telegramSupport: 'Support',
            showConfigs: 'Configs',
            connectionGuide: 'Connection Guide',
            configLinks: 'Config Links',
            configLinksDesc: 'You can use the following links to use your configs in other applications.',
            subscriptionLink: 'Subscription Link',
            close: 'Close',
            copy: 'Copy',
            copied: 'Copied',
            vMessConfig: 'VMESS Config',
            vLessConfig: 'VLESS Config',
            trojanConfig: 'Trojan Config',
            shadowsocksConfig: 'Shadowsocks Config',
            configLink: 'Config Link',
            downloadApps: 'Download Apps',
            downloadAppsDesc: 'Download the appropriate app for your operating system',
            hiddifyWindows: 'Hiddify Windows',
            hiddifyAndroid: 'Hiddify Android',
            hiddifyApple: 'Hiddify Apple',
            singboxAndroid: 'Sing-box Android',
            singboxApple: 'Sing-box Apple',
            addSubscription: 'Add Subscription',
            addSubscriptionDesc: 'Click on the relevant button for the app you have installed',
            hiddifySettings: 'Hiddify Settings',
            singboxSettings: 'Sing-box Settings',
            connectAndUse: 'Connect and Use',
            connectAndUseDesc: 'Click CONNECT in Hiddify app or ENABLE in Sing-box. It is recommended to update your subscription link daily from within the app.',
            qrCode: 'QR Code',
            download: 'Download',
            start: 'Start',
            settings: 'Settings',
            enter: 'Enter'
          }
        },

        init() {
          Alpine.store('app', this);

          Alpine.data('qrModal', () => ({
            title: '',
            get closeText() {
              return this.$store.app.translations[this.$store.app.currentLang].close;
            },
            setTitle(newTitle) {
              this.title = newTitle;
            }
          }));

          const savedTheme = localStorage.getItem('theme');
          if (savedTheme) {
            this.darkMode = savedTheme === 'dark';
            document.documentElement.setAttribute('data-bs-theme', savedTheme);
          } else {
            this.darkMode = document.documentElement.getAttribute('data-bs-theme') === 'dark';
          }
          
          const savedLang = localStorage.getItem('lang');
          if (savedLang) {
            this.currentLang = savedLang;
            this.applyLanguage(savedLang);
          }

          const savedAvatar = localStorage.getItem('avatarUrl');
          if (savedAvatar) {
            this.avatarUrl = savedAvatar;
          }

          document.addEventListener('show-qr', async function(e) {
            await loadQRCode();
            const qrModal = new bootstrap.Modal(document.getElementById('qr-modal'));
            const qrContainer = document.getElementById('qr-canvas');
            
            const title = e.detail.name || e.detail.url;
            window.dispatchEvent(new CustomEvent('show-qr-title', { detail: title }));
            
            qrContainer.innerHTML = '';
            
            new QRCode(qrContainer, {
              text: e.detail.url,
              width: 256,
              height: 256,
              colorDark: '#000000',
              colorLight: '#ffffff'
            });
            
            qrModal.show();
          });
        },

        toggleTheme() {
          this.darkMode = !this.darkMode;
          const theme = this.darkMode ? 'dark' : 'light';
          document.documentElement.setAttribute('data-bs-theme', theme);
          localStorage.setItem('theme', theme);
        },

        toggleLang() {
          this.currentLang = this.currentLang === 'fa' ? 'en' : 'fa';
          this.applyLanguage(this.currentLang);
          localStorage.setItem('lang', this.currentLang);
        },

        applyLanguage(lang) {
          if (lang === 'en') {
            document.documentElement.setAttribute('dir', 'ltr');
            document.documentElement.setAttribute('lang', 'en');
          } else {
            document.documentElement.setAttribute('dir', 'rtl');
            document.documentElement.setAttribute('lang', 'fa');
          }
        },

        formatBytes(bytes) {
          if (!bytes || bytes.toString().startsWith('{')) return '0';
          bytes = parseInt(bytes);
          if (bytes === 0) return '0 B';
          
          const units = ['B', 'KB', 'MB', 'GB', 'TB'];
          let i = 0;
          
          while (bytes >= 1024 && i < units.length - 1) {
            bytes /= 1024;
            i++;
          }
          
          return `${bytes.toFixed(2)} ${units[i]}`;
        },

        getStatusText(statusValue) {
          const statusMap = {
            'active': this.translations[this.currentLang].active,
            'limited': this.translations[this.currentLang].limited,
            'expired': this.translations[this.currentLang].expired,
            'disabled': this.translations[this.currentLang].disabled
          };
          return statusValue.startsWith('{') ? this.translations[this.currentLang].anonymous : (statusMap[statusValue] || this.translations[this.currentLang].anonymous);
        },

        getExpireText(expire) {
          if (!expire) return this.translations[this.currentLang].unlimited;
          if (expire.startsWith('{')) return this.translations[this.currentLang].anonymous;
          
          if (this.currentLang === 'fa') {
            return `تا ${new Date(expire).toLocaleDateString('fa-IR')}`;
          } else {
            return `Until ${new Date(expire).toLocaleDateString('en-US')}`;
          }
        },

        getTrafficText(usedTraffic, dataLimit) {
          if (dataLimit === null || dataLimit === 'null') {
            return `<span class="traffic-value">${this.formatBytes(usedTraffic)} / ∞</span>`;
          }
          
          if (dataLimit.toString().startsWith('{')) {
            return this.translations[this.currentLang].anonymous;
          }
          
          return `<span class="traffic-value">${this.formatBytes(usedTraffic)} / ${this.formatBytes(dataLimit)}</span>`;
        },

        importHiddify() {
          window.location.href = `hiddify://import/${'{{ user.subscription_url }}'}`;
        },
        
        importSingbox() {
          window.location.href = `sing-box://import-remote-profile?url=${'{{ user.subscription_url }}'}#{{ user.username }}`;
        },

        copyLink(link, button) {
          navigator.clipboard.writeText(link);
          button.innerHTML = `<svg class='bi' width='16' height='16'><use href='#check-square'></use></svg> <span>${this.translations[this.currentLang].copied}</span>`;
          button.classList.add('copied');
          
          setTimeout(() => {
            button.innerHTML = `<svg class='bi' width='16' height='16'><use href='#copy'></use></svg> <span>${this.translations[this.currentLang].copy}</span>`;
            button.classList.remove('copied');
          }, 2000);
        },

        setAvatar(url) {
          this.avatarUrl = url;
          localStorage.setItem('avatarUrl', url);
        },
        
        getInitial(username) {
          if (!username || username.startsWith('{')) return '?';
          return username.charAt(0).toUpperCase();
        }
      };
    });
  </script>
  
  <!-- -------------- EMERGENCY BUTTON SECTION SCRIPT-------------- -->
  
  <script>
  function emergencyWidget() {
    return {
      used: false,
      loading: false,
      message: '',
      title: 'شارژ اضطراری',
      subtitle: 'در صورت اتمام حجم یا زمان، فعال میشود',  // مقدار پیش‌فرض برای کاربرانی که وضعیت active دارند

      username: '{{ user.username }}',
      statusValue: '{{ user.status.value }}',

      emergencyBase() {
        return window.location.origin.replace(":4178", "");
      },

      async init() {
        // تنظیم عنوان و متن
        if (this.statusValue === 'active') {
          this.subtitle = 'در صورت اتمام حجم یا زمان، فعال میشود';  // برای کاربران فعال
          this.title = 'شارژ اضطراری';
        } else if (this.statusValue === 'limited') {
          this.subtitle = 'فقط یکبار در طول هر دوره تمدید میتوانید از شارژ اضطراری رایگان استفاده کنید.';
          this.title = 'شارژ اضطراری';
        }

        if (this.statusValue === 'limited' || this.statusValue === 'expired') {
          this.showButton = true;
        }

        try {
          const res = await fetch(`${this.emergencyBase()}/emergency/${this.username}`);

          if (!res.ok) {
            this.message = 'عدم اتصال به سرویس اضطراری.';
            return;
          }

          const j = await res.json();

          this.used = !!j.used;

          if (this.used) {
            this.message = 'شما قبلاً از شارژ اضطراری استفاده کرده‌اید.';
            this.showButton = false;
          }

        } catch (e) {
          this.message = 'عدم اتصال به سرویس اضطراری.';
        }
      },

      async requestEmergency() {
        if (!confirm('آیا مطمئن هستید؟ شارژ اضطراری فقط یکبار قابل استفاده است.')) {
          return;
        }

        this.loading = true;

        try {
          const res = await fetch(
            `${this.emergencyBase()}/emergency/${this.username}/grant`,
            {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({
                add_bytes: 500 * 1024 * 1024,   // 500 MB
                add_seconds: 12 * 3600          // 12 hours
              })
            }
          );

          if (!res.ok) {
            this.message = "خطا: " + (await res.text());
            this.loading = false;
            return;
          }

          this.message = "شارژ اضطراری با موفقیت اعمال شد.";
          this.used = true;
          this.showButton = false;

          setTimeout(() => location.reload(), 1500);

        } catch (e) {
          this.message = "عدم اتصال به سرویس اضطراری.";
        }

        this.loading = false;
      }
    };
  }
</script>

<!-- -------------- EMERGENCY BUTTON SECTION SCRIPT END-------------- -->
  
</head>

<body>
<svg xmlns="http://www.w3.org/2000/svg" class="d-none">
  <symbol id="android" viewBox="0 0 24 24"><path d="M17.6 9.48l1.84-3.18c.16-.31.04-.69-.26-.85-.29-.15-.65-.06-.83.22l-1.88 3.24c-2.86-1.21-6.08-1.21-8.94 0L5.65 5.67c-.19-.29-.58-.38-.87-.2-.28.18-.37.54-.22.83L6.4 9.48C3.3 11.25 1.28 14.44 1 18h22c-.28-3.56-2.3-6.75-5.4-8.52zM7 15.25c-.69 0-1.25-.56-1.25-1.25S6.31 12.75 7 12.75s1.25.56 1.25 1.25S7.69 15.25 7 15.25zm10 0c-.69 0-1.25-.56-1.25-1.25s.56-1.25 1.25-1.25 1.25.56 1.25 1.25-.56 1.25-1.25 1.25z"/></symbol>
  <symbol id="microsoft" viewBox="0 0 16 16"><path d="M7.462 0H0v7.19h7.462V0zM16 0H8.538v7.19H16V0zM7.462 8.211H0V16h7.462V8.211zm8.538 0H8.538V16H16V8.211z"/></symbol>
  <symbol id="apple" viewBox="0 0 16 16"><path d="M11.182.008C11.148-.03 9.923.023 8.857 1.18c-1.066 1.156-.902 2.482-.878 2.516s1.52.087 2.475-1.258.762-2.391.728-2.43m3.314 11.733c-.048-.096-2.325-1.234-2.113-3.422s1.675-2.789 1.698-2.854-.597-.79-1.254-1.157a3.7 3.7 0 0 0-1.563-.434c-.108-.003-.483-.095-1.254.116-.508.139-1.653.589-1.968.607-.316.018-1.256-.522-2.267-.665-.647-.125-1.333.131-1.824.328-.49.196-1.422.754-2.074 2.237-.652 1.482-.311 3.83-.067 4.56s.625 1.924 1.273 2.796c.576.984 1.34 1.667 1.659 1.899s1.219.386 1.843.067c.502-.308 1.408-.485 1.766-.472.357.013 1.061.154 1.782.539.571.197 1.111.115 1.652-.105.541-.221 1.324-1.059 2.238-2.758q.52-1.185.473-1.282"/></symbol>
  <symbol id="cloud-plus" viewBox="0 0 16 16"><path fill="none" stroke="currentColor" stroke-width="1" stroke-linecap="round" d="M8 5.5v5M5.5 8h5"/><path fill="none" stroke="currentColor" stroke-width="1" d="M4.406 3.342A5.53 5.53 0 0 1 8 2c2.69 0 4.923 2 5.166 4.579C14.758 6.804 16 8.137 16 9.773 16 11.569 14.502 13 12.687 13H3.781C1.708 13 0 11.366 0 9.318c0-1.763 1.266-3.223 2.942-3.593.143-.863.698-1.723 1.464-2.383z"/></symbol>
  <symbol id="person-circle" viewBox="0 0 16 16"><circle cx="8" cy="8" r="8" fill="currentColor" opacity="0.3"/><path d="M11 6a3 3 0 1 1-6 0 3 3 0 0 1 6 0"/><path fill-rule="evenodd" d="M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8zm8-7a7 7 0 0 0-5.468 11.37C3.242 11.226 4.805 10 8 10s4.757 1.225 5.468 2.37A7 7 0 0 0 8 1"/></symbol>
  <symbol id="clock" viewBox="0 0 16 16"><circle cx="8" cy="8" r="8" fill="currentColor" opacity="0.3"/><path d="M8 3.5a.5.5 0 0 0-1 0V9a.5.5 0 0 0 .252.434l3.5 2a.5.5 0 0 0 .496-.868L8 8.71V3.5z"/><path d="M8 16A8 8 0 1 0 8 0a8 8 0 0 0 0 16zm7-8A7 7 0 1 1 1 8a7 7 0 0 1 14 0z"/></symbol>
  <symbol id="arrow-down-circle" viewBox="0 0 16 16"><circle cx="8" cy="8" r="8" fill="currentColor" opacity="0.3"/><path fill-rule="evenodd" d="M1 8a7 7 0 1 0 14 0A7 7 0 0 0 1 8m15 0A8 8 0 1 1 0 8a8 8 0 0 1 16 0M8.5 4.5a.5.5 0 0 0-1 0v5.793L5.354 8.146a.5.5 0 1 0-.708.708l3 3a.5.5 0 0 0 .708 0l3-3a.5.5 0 0 0-.708-.708L8.5 10.293z"/></symbol>
  <symbol id="check-circle" viewBox="0 0 16 16"><circle cx="8" cy="8" r="8" fill="currentColor" opacity="0.3"/><path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14m0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16"/><path d="m10.97 4.97-.02.022-3.473 4.425-2.093-2.094a.75.75 0 0 0-1.06 1.06L6.97 11.03a.75.75 0 0 0 1.079-.02l3.992-4.99a.75.75 0 0 0-1.071-1.05"/></symbol>
  <symbol id="x-circle" viewBox="0 0 16 16"><circle cx="8" cy="8" r="8" fill="currentColor" opacity="0.3"/><path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14m0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16zM4.646 4.646a.5.5 0 0 1 .708 0L8 7.293l2.646-2.647a.5.5 0 0 1 .708.708L8.707 8l2.647 2.646a.5.5 0 0 1-.708.708L8 8.707l-2.646 2.647a.5.5 0 0 1-.708-.708L7.293 8 4.646 5.354a.5.5 0 0 1 0-.708"/></symbol>
  <symbol id="cloud-arrow-down" viewBox="0 0 16 16"><path fill="none" stroke="currentColor" stroke-width="1" stroke-linecap="round" stroke-linejoin="round" d="M8 9.5v-4m0 4l2-2m-4 0l2 2"/><path fill="none" stroke="currentColor" stroke-width="1" d="M4.406 3.342A5.53 5.53 0 0 1 8 2c2.69 0 4.923 2 5.166 4.579C14.758 6.804 16 8.137 16 9.773 16 11.569 14.502 13 12.687 13H3.781C1.708 13 0 11.366 0 9.318c0-1.763 1.266-3.223 2.942-3.593.143-.863.698-1.723 1.464-2.383z"/></symbol>
  <symbol id="copy" viewBox="0 0 16 16"><path fill="none" stroke="currentColor" stroke-width="1" d="M4 2a1 1 0 0 1 1-1h8a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V2z"/><path fill="none" stroke="currentColor" stroke-width="1" d="M2 6a1 1 0 0 1 1-1h8a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V6z"/></symbol>
  <symbol id="check-square" viewBox="0 0 16 16"><path d="M14 1a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1h12zM2 0a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V2a2 2 0 0 0-2-2H2z"/><path d="M10.97 4.97a.75.75 0 0 1 1.071 1.05l-3.992 4.99a.75.75 0 0 1-1.08.02L4.324 8.384a.75.75 0 1 1 1.06-1.06l2.094 2.093 3.473-4.425a.235.235 0 0 1 .02-.022z"/></symbol>
  <symbol id="cloud-check" viewBox="0 0 16 16"><path fill="none" stroke="currentColor" stroke-width="1" stroke-linecap="round" stroke-linejoin="round" d="M6 8.5l1.5 1.5L10 7"/><path fill="none" stroke="currentColor" stroke-width="1" d="M4.406 3.342A5.53 5.53 0 0 1 8 2c2.69 0 4.923 2 5.166 4.579C14.758 6.804 16 8.137 16 9.773 16 11.569 14.502 13 12.687 13H3.781C1.708 13 0 11.366 0 9.318c0-1.763 1.266-3.223 2.942-3.593.143-.863.698-1.723 1.464-2.383z"/></symbol>
  <symbol id="info-circle" viewBox="0 0 16 16"><path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14m0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16zM8.93 6.588l-2.29.287-.082.38.45.083c.294.07.352.176.288.469l-.738 3.468c-.194.897.105 1.319.808 1.319.545 0 1.178-.252 1.465-.598l.088-.416c-.2.176-.492.246-.686.246-.275 0-.375-.193-.304-.533zM9 4.5a1 1 0 1 1-2 0 1 1 0 0 1 2 0"/></symbol>
  <symbol id="filter-circle" viewBox="0 0 16 16"><path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14m0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16zM7 11.5a.5.5 0 0 1 .5-.5h1a.5.5 0 0 1 0 1h-1a.5.5 0 0 1-.5-.5m-2-3a.5.5 0 0 1 .5-.5h5a.5.5 0 0 1 0 1h-5a.5.5 0 0 1-.5-.5m-2-3a.5.5 0 0 1 .5-.5h9a.5.5 0 0 1 0 1h-9a.5.5 0 0 1-.5-.5"/></symbol>
  <symbol id="sun" viewBox="0 0 16 16"><path d="M8 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM8 0a.5.5 0 0 1 .5.5v2a.5.5 0 0 1-1 0v-2A.5.5 0 0 1 8 0zm0 13a.5.5 0 0 1 .5.5v2a.5.5 0 0 1-1 0v-2A.5.5 0 0 1 8 13zm8-5a.5.5 0 0 1-.5.5h-2a.5.5 0 0 1 0-1h2a.5.5 0 0 1 .5.5zM3 8a.5.5 0 0 1-.5.5h-2a.5.5 0 0 1 0-1h2A.5.5 0 0 1 3 8zm10.657-5.657a.5.5 0 0 1 0 .707l-1.414 1.415a.5.5 0 1 1-.707-.708l1.414-1.414a.5.5 0 0 1 .707 0zm-9.193 9.193a.5.5 0 0 1 0 .707L3.05 13.657a.5.5 0 0 1-.707-.707l1.414-1.414a.5.5 0 0 1 .707 0zm9.193 2.121a.5.5 0 0 1-.707 0l-1.414-1.414a.5.5 0 0 1 .707-.707l1.414 1.414a.5.5 0 0 1 0 .707zM4.464 4.465a.5.5 0 0 1-.707 0L2.343 3.05a.5.5 0 1 1 .707-.707l1.414 1.414a.5.5 0 0 1 0 .708z"/></symbol>
  <symbol id="moon" viewBox="0 0 16 16"><path d="M6 .278a.768.768 0 0 1 .08.858 7.208 7.208 0 0 0-.878 3.46c0 4.021 3.278 7.277 7.318 7.277.527 0 1.04-.055 1.533-.16a.787.787 0 0 1 .81.316.733.733 0 0 1-.031.893A8.349 8.349 0 0 1 8.344 16C3.734 16 0 12.286 0 7.71 0 4.266 2.114 1.312 5.124.06A.752.752 0 0 1 6 .278z"/></symbol>
  <symbol id="qr-code" viewBox="0 0 24 24"><path d="M3 11h8V3H3v8zm2-6h4v4H5V5zM3 21h8v-8H3v8zm2-6h4v4H5v-4zm8-12v8h8V3h-8zm6 6h-4V5h4v4zM13 13h2v2h-2zM15 15h2v2h-2zM13 17h2v2h-2zM11 13h2v2h-2zM15 17h2v2h-2zM17 13h2v2h-2zM17 17h2v2h-2zM19 19h2v2h-2zM19 15h2v2h-2z"/></symbol>
  <symbol id="question-circle" viewBox="0 0 16 16"><path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14zm0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16z"/><path d="M5.255 5.786a.237.237 0 0 0 .241.247h.825c.138 0 .248-.113.266-.25.09-.656.54-1.134 1.342-1.134.686 0 1.314.343 1.314 1.168 0 .635-.374.927-.965 1.371-.673.489-1.206 1.06-1.168 1.987l.003.217a.25.25 0 0 0 .25.246h.811a.25.25 0 0 0 .25-.25v-.105c0-.718.273-.927 1.01-1.486.609-.463 1.244-.977 1.244-2.056 0-1.511-1.276-2.241-2.673-2.241-1.267 0-2.655.59-2.75 2.286zm1.557 5.763c0 .533.425.927 1.01.927.609 0 1.028-.394 1.028-.927 0-.552-.42-.94-1.029-.94-.584 0-1.009.388-1.009.94z"/></symbol>
  <symbol id="translate" viewBox="0 0 16 16"><path d="M4.545 6.714 4.11 8H3l1.862-5h1.284L8 8H6.833l-.435-1.286zm1.634-.736L5.5 3.956h-.049l-.679 2.022z"/><path d="M0 2a2 2 0 0 1 2-2h7a2 2 0 0 1 2 2v3h3a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-3H2a2 2 0 0 1-2-2zm2-1a1 1 0 0 0-1 1v7a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1V2a1 1 0 0 0-1-1zm7.138 9.995q.289.451.63.846c-.748.575-1.673 1.001-2.768 1.292.178.217.451.635.555.867 1.125-.359 2.08-.844 2.886-1.494.777.665 1.739 1.165 2.93 1.472.133-.254.414-.673.629-.89-1.125-.253-2.057-.694-2.82-1.284.681-.747 1.222-1.651 1.621-2.757H14V8h-3v1.047h.765c-.318.844-.74 1.546-1.272 2.13a6 6 0 0 1-.415-.492 2 2 0 0 1-.94.31"/></symbol>
  <symbol id="gear-fill" viewBox="0 0 16 16"><path d="M9.405 1.05c-.413-1.4-2.397-1.4-2.81 0l-.1.34a1.464 1.464 0 0 1-2.105.872l-.31-.17c-1.283-.698-2.686.705-1.987 1.987l.169.311c.446.82.023 1.841-.872 2.105l-.34.1c-1.4.413-1.4 2.397 0 2.81l.34.1a1.464 1.464 0 0 1 .872 2.105l-.17.31c-.698 1.283.705 2.686 1.987 1.987l.311-.169a1.464 1.464 0 0 1 2.105.872l.1.34c.413 1.4 2.397 1.4 2.81 0l.1-.34a1.464 1.464 0 0 1 2.105-.872l.31.17c1.283.698 2.686-.705 1.987-1.987l-.169-.311a1.464 1.464 0 0 1 .872-2.105l.34-.1c1.4-.413 1.4-2.397 0-2.81l-.34-.1a1.464 1.464 0 0 1-.872-2.105l.17-.31c.698-1.283-.705-2.686-1.987-1.987l-.311.169a1.464 1.464 0 0 1-2.105-.872l-.1-.34zM8 10.93a2.929 2.929 0 1 1 0-5.86 2.929 2.929 0 0 1 0 5.858z"/></symbol>
</svg>

  <div class="container my-container" x-data="app" x-cloak>
    <div class="page-header">
      <div class="header-title-section">
        <div class="user-avatar">
          <template x-if="avatarUrl">
            <img :src="avatarUrl" alt="User Avatar">
          </template>
          <template x-if="!avatarUrl">
            <div class="user-avatar-placeholder" x-text="getInitial('{{ user.username }}')"></div>
          </template>
        </div>
        <h2 class="my-text-heading fw-bold mb-0" x-text="translations[currentLang].subscriptionInfo"></h2>
      </div>
      
      <div class="header-buttons-section">
        <button class="lang-toggle" @click="toggleLang">
          <svg class="bi"><use href="#translate"></use></svg>
        </button>
        <button class="theme-toggle" @click="toggleTheme">
          <svg class="bi" x-show="darkMode"><use href="#sun"></use></svg>
          <svg class="bi" x-show="!darkMode"><use href="#moon"></use></svg>
        </button>
      </div>
    </div>
    
    <div class="row row-cols-2 row-cols-md-4 g-3 mb-4">
      <div class="col">
        <div class="my-block" x-data="{username: '{{ user.username }}'}">
          <div class="d-flex flex-row align-items-center mb-3">
            <svg class="bi"><use href="#person-circle"></use></svg>
            <h5 class="my-text-heading mb-0" x-text="translations[currentLang].username"></h5>
          </div>
          <p class="text-truncate my-text-content mb-0" x-text="username.startsWith('{') ? translations[currentLang].anonymous : username"></p>
        </div>
      </div>
      
      <div class="col">
        <div class="my-block" x-data="{statusValue: '{{ user.status.value }}'}">
          <div class="d-flex flex-row align-items-center mb-3">
            <svg class="bi"><use x-bind:href="statusValue == 'active' || statusValue.startsWith('{') ? '#check-circle' : '#x-circle'"></use></svg>
            <h5 class="my-text-heading mb-0" x-text="translations[currentLang].status"></h5>
          </div>
          <p class="text-truncate my-text-content mb-0" x-text="getStatusText(statusValue)"></p>
        </div>
      </div>
      
      <div class="col">
        <div class="my-block" x-data="{expire: '{% if user.expire %}{{ user.expire | datetime }}{% endif %}'}">
          <div class="d-flex flex-row align-items-center mb-3">
            <svg class="bi"><use href="#clock"></use></svg>
            <h5 class="my-text-heading mb-0" x-text="translations[currentLang].duration"></h5>
          </div>
          <p class="text-truncate my-text-content mb-0" x-text="getExpireText(expire)"></p>
        </div>
      </div>
      
      <div class="col">
        <div class="my-block" x-data="{
          usedTraffic: {{ user.used_traffic }},
          dataLimit: {{ user.data_limit if user.data_limit else 'null' }}
        }">
          <div class="d-flex flex-row align-items-center mb-3">
            <svg class="bi"><use href="#arrow-down-circle"></use></svg>
            <h5 class="my-text-heading mb-0" x-text="translations[currentLang].traffic"></h5>
          </div>
          <p class="text-truncate my-text-content mb-0" x-html="getTrafficText(usedTraffic, dataLimit)"></p>
        </div>
      </div>
    </div>

<!-- -------------- EMERGENCY BUTTON SECTION -------------- -->
<div class="row g-3 mb-3" x-data="emergencyWidget()" x-cloak>
  <div class="col">
    <div class="my-block emergency-block p-3 rounded" :class="{'height-adjusted': statusValue === 'limited'}">
      <div class="d-flex align-items-center justify-content-between">

        <div>
          <!-- عنوان شارژ اضطراری -->
          <div class="fw-semibold fs-5 my-text-heading d-flex align-items-center" style="font-weight: 500 !important;">
            <span x-text="title"></span>
            <!-- عبارت برای کاربران با وضعیت active -->
            <span x-show="statusValue === 'active'" style="font-size: 0.8rem; margin-left: 5px;">
            </span>
			<span style="font-size: 0.8rem; margin-left: 5px; font-weight: 500; margin-right: 5px;" x-text="subtitle">
			</span>
          </div>
        </div>

        <div>
          <!-- دکمه شارژ اضطراری فقط برای کاربرانی که وضعیتشان محدود است نمایش داده می‌شود -->
          <button
            x-show="statusValue === 'limited' && !used"
            @click="requestEmergency"
            :disabled="loading"
            class="btn btn-warning fw-bold emergency-btn"
            :class="{ 'opacity-75': loading }">
            <span x-show="!loading">شارژ اضطراری</span>
            <span x-show="loading">در حال اعمال…</span>
          </button>

          <!-- دکمه شارژ اضطراری استفاده شده -->
          <button
            x-show="statusValue === 'limited' && used"
            class="btn btn-outline-secondary emergency-used-btn"
            disabled>
            شارژ اضطراری استفاده شده
          </button>
        </div>

      </div>

      <template x-if="message">
        <div class="mt-2 small fw-semibold my-text-content" x-text="message"></div>
      </template>
    </div>
  </div>
</div>
<!-- -------------- EMERGENCY BUTTON SECTION END-------------- -->

    <div class="connection-buttons">
     <a class="btn my-btn-outline" href="https://t.me/oneplusvpn_support" role="button" rel="noopener noreferrer" target="_blank">
      <svg class="bi me-1"><use href="#info-circle"></use></svg>
       <span x-text="translations[currentLang].telegramSupport"></span>
     </a>
    <button class="btn my-btn-outline" data-bs-toggle="modal" data-bs-target="#get-link-modal">
     <svg class="bi me-1"><use href="#filter-circle"></use></svg>
      <span x-text="translations[currentLang].showConfigs"></span>
    </button>
   </div>

    <h3 class="my-text-heading mb-4 fw-bold d-flex align-items-center gap-2" 
        :class="currentLang === 'fa' ? 'text-start' : 'text-end'"
        style="font-size: 1.5rem; letter-spacing: -0.5px;">
        <svg class="bi" style="width: 1.2em; height: 1.2em;"><use href="#question-circle"></use></svg>
        <span x-text="translations[currentLang].connectionGuide"></span>
    </h3>
    
    <div class="modal my-modal fade" id="get-link-modal" tabindex="-1" aria-labelledby="linkModalLabel" aria-hidden="true">
      <div class="modal-dialog modal-dialog-centered">
        <div class="modal-content">
          <div class="modal-header position-relative">
            <h5 class="my-text-heading fw-semibold mb-0" id="linkModalLabel" x-text="translations[currentLang].configLinks"></h5>
            <button type="button" 
                    class="modal-close-btn" 
                    data-bs-dismiss="modal"
                    x-text="translations[currentLang].close">
            </button>
          </div>
          <div class="modal-body" x-data="{
            subscriptionUrl: '{{ user.subscription_url }}',
            links: [{% for link in user.links %}'{{ link }}'{% if not loop.last %}, {% endif %}{% endfor %}],
            getLinkName(link) {
              if (link === this.subscriptionUrl) return translations[currentLang].subscriptionLink;
              
              const protocols = {
                'vmess://': link => {
                  try { 
                    const config = JSON.parse(atob(link.replace('vmess://', '')));
                    return config.ps || translations[currentLang].vMessConfig;
                  } catch { 
                    return translations[currentLang].vMessConfig; 
                  }
                },
                'vless://': link => {
                  try {
                    const url = new URL(link);
                    const params = new URLSearchParams(url.hash.slice(1));
                    return params.get('remark') || decodeURIComponent(url.hash.slice(1)) || translations[currentLang].vLessConfig;
                  } catch {
                    return translations[currentLang].vLessConfig;
                  }
                },
                'trojan://': link => {
                  try {
                    const url = new URL(link);
                    const params = new URLSearchParams(url.hash.slice(1));
                    return params.get('remark') || translations[currentLang].trojanConfig;
                  } catch {
                    return translations[currentLang].trojanConfig;
                  }
                },
                'ss://': link => {
                  try {
                    const decoded = atob(link.replace('ss://', '').split('@')[0]);
                    const parts = decoded.split(':');
                    return parts.length > 1 ? decodeURIComponent(parts[1]) || translations[currentLang].shadowsocksConfig : translations[currentLang].shadowsocksConfig;
                  } catch {
                    return translations[currentLang].shadowsocksConfig;
                  }
                }
              };
              
              for (const prefix in protocols) {
                if (link.startsWith(prefix)) {
                  return protocols[prefix](link);
                }
              }
              
              try {
                const url = new URL(link);
                const params = new URLSearchParams(url.hash.slice(1));
                return params.get('remark') || decodeURIComponent(url.hash.slice(1)) || translations[currentLang].configLink;
              } catch {
                return link.includes('#') ? decodeURIComponent(link.split('#')[1]) || translations[currentLang].configLink : translations[currentLang].configLink;
              }
            }
          }">
            <p class="my-text-content mb-3" x-text="translations[currentLang].configLinksDesc"></p>
            <div class="mb-3">
              <div class="config-link">
                <div class="config-link-name" x-text="translations[currentLang].subscriptionLink"></div>
                <div class="config-link-buttons">
                  <button class="config-link-qr-btn" @click="$dispatch('show-qr', {url: subscriptionUrl, name: translations[currentLang].subscriptionLink})">
                    <svg class="bi"><use href="#qr-code"></use></svg>
                  </button>
                  <button class="config-link-copy-btn" 
                  @click="copyLink(subscriptionUrl, $el)" 
                  x-html="`<svg class='bi' width='14' height='14'><use href='#copy'></use></svg> <span>${translations[currentLang].copy}</span>`">
          </button>
                </div>
              </div>
              
              <template x-for="(link, index) in links" :key="index">
                <div class="config-link">
                  <div class="config-link-name" x-text="getLinkName(link)"></div>
                  <div class="config-link-buttons">
                    <button class="config-link-qr-btn" @click="$dispatch('show-qr', {url: link, name: getLinkName(link)})">
                      <svg class="bi"><use href="#qr-code"></use></svg>
                    </button>
                    <button class="config-link-copy-btn" 
                    @click="copyLink(link, $el)" 
                    x-html="`<svg class='bi' width='16' height='16'><use href='#copy'></use></svg> <span>${translations[currentLang].copy}</span>`">
            </button>
                  </div>
                </div>
              </template>
            </div>
          </div>
        </div>
      </div>
    </div>
    
    <div class="tab-content">
      <div id="tab-pc" class="tab-pane my-tab-pane fade show active">
        <div class="row g-3">
          <div class="col-12 col-lg-6">
            <div class="my-block-big h-100">
              <span class="my-step-counter mb-3"></span>
              <h5 class="my-text-heading fw-semibold" x-text="translations[currentLang].downloadApps"></h5>
              <p class="my-text-content" x-text="translations[currentLang].downloadAppsDesc"></p>
              
              <div class="download-buttons">
                <div class="config-link">
                  <div class="config-link-name">
                    <svg class="bi" width="16" height="16"><use href="#microsoft"></use></svg>
                    <span x-text="translations[currentLang].hiddifyWindows"></span>
                  </div>
                  <div class="config-link-buttons">
                    <a class="download-button" 
                    href="https://github.com/hiddify/hiddify-next/releases/latest/download/Hiddify-Windows-Setup-x64.exe" 
                    role="button" 
                    rel="noopener noreferrer" 
                    target="_blank" 
                    @click="handleButtonFeedback($el, $el.innerHTML, `<svg class='bi' width='16' height='16'><use href='#cloud-check'></use></svg> <span>${translations[currentLang].start}</span>`); setTimeout(() => window.open('https://github.com/hiddify/hiddify-next/releases/latest/download/Hiddify-Windows-Setup-x64.exe', '_blank'), 300);">
                   <svg class="bi" width="16" height="16"><use href="#cloud-arrow-down"></use></svg>
                   <span x-text="translations[currentLang].download || 'دانلود'"></span>
                 </a>
                  </div>
                </div>

                <div class="config-link">
                  <div class="config-link-name">
                    <svg class="bi" width="16" height="16"><use href="#android"></use></svg>
                    <span x-text="translations[currentLang].hiddifyAndroid"></span>
                  </div>
                  <div class="config-link-buttons">
                    <a class="download-button" 
                       href="https://github.com/hiddify/hiddify-next/releases/latest/download/Hiddify-Android-universal.apk" 
                       role="button" 
                       rel="noopener noreferrer" 
                       target="_blank" 
                       @click="handleButtonFeedback($el, $el.innerHTML, `<svg class='bi' width='16' height='16'><use href='#cloud-check'></use></svg> <span>${translations[currentLang].start}</span>`); setTimeout(() => window.open('https://github.com/hiddify/hiddify-next/releases/latest/download/Hiddify-Android-universal.apk', '_blank'), 300);">
                       <svg class="bi" width="16" height="16"><use href="#cloud-arrow-down"></use></svg>
                      <span x-text="translations[currentLang].download || 'دانلود'"></span>
                    </a>
                  </div>
                </div>

                <div class="config-link">
                  <div class="config-link-name">
                    <svg class="bi" width="16" height="16"><use href="#apple"></use></svg>
                    <span x-text="translations[currentLang].hiddifyApple"></span>
                  </div>
                  <div class="config-link-buttons">
                    <a class="download-button" 
                       href="https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532" 
                       role="button" 
                       rel="noopener noreferrer" 
                       target="_blank" 
                       @click="handleButtonFeedback($el, $el.innerHTML, `<svg class='bi' width='16' height='16'><use href='#cloud-check'></use></svg> <span>${translations[currentLang].start}</span>`); setTimeout(() => window.open('https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532', '_blank'), 300);">
                      <svg class="bi" width="16" height="16"><use href="#cloud-arrow-down"></use></svg>
                      <span x-text="translations[currentLang].download || 'دانلود'"></span>
                    </a>
                  </div>
                </div>

                <div class="config-link">
                  <div class="config-link-name">
                    <svg class="bi" width="16" height="16"><use href="#android"></use></svg>
                    <span x-text="translations[currentLang].singboxAndroid"></span>
                  </div>
                  <div class="config-link-buttons">
                    <a class="download-button" 
                       href="https://github.com/SagerNet/sing-box/releases/download/v1.11.6/SFA-1.11.6-universal.apk" 
                       role="button" 
                       rel="noopener noreferrer" 
                       target="_blank" 
                       @click="handleButtonFeedback($el, $el.innerHTML, `<svg class='bi' width='16' height='16'><use href='#cloud-check'></use></svg> <span>${translations[currentLang].start}</span>`); setTimeout(() => window.open('https://github.com/SagerNet/sing-box/releases/download/v1.11.6/SFA-1.11.6-universal.apk', '_blank'), 300);">
                      <svg class="bi" width="16" height="16"><use href="#cloud-arrow-down"></use></svg>
                      <span x-text="translations[currentLang].download || 'دانلود'"></span>
                    </a>
                  </div>
                </div>

                <div class="config-link">
                  <div class="config-link-name">
                    <svg class="bi" width="16" height="16"><use href="#apple"></use></svg>
                    <span x-text="translations[currentLang].singboxApple"></span>
                  </div>
                  <div class="config-link-buttons">
                    <a class="download-button" 
                       href="https://apps.apple.com/us/app/sing-box-vt/id6673731168" 
                       role="button" 
                       rel="noopener noreferrer" 
                       target="_blank" 
                       @click="handleButtonFeedback($el, $el.innerHTML, `<svg class='bi' width='16' height='16'><use href='#cloud-check'></use></svg> <span>${translations[currentLang].start}</span>`); setTimeout(() => window.open('https://apps.apple.com/us/app/sing-box-vt/id6673731168', '_blank'), 300);">
                      <svg class="bi" width="16" height="16"><use href="#cloud-arrow-down"></use></svg>
                      <span x-text="translations[currentLang].download || 'دانلود'"></span>
                    </a>
                  </div>
                </div>
              </div>
            </div>
          </div>
          
          <div class="col-12 col-lg-6">
            <div class="equal-height-container">
              <div class="my-block-big mb-3">
                <span class="my-step-counter mb-3"></span>
                <h5 class="my-text-heading fw-semibold" x-text="translations[currentLang].addSubscription"></h5>
                <p class="my-text-content" x-text="translations[currentLang].addSubscriptionDesc"></p>
                
                <div class="download-buttons">
                  <div class="config-link">
                    <div class="config-link-name">
                      <svg class="bi" width="16" height="16"><use href="#gear-fill"></use></svg>
                      <span x-text="translations[currentLang].hiddifySettings"></span>
                    </div>
                    <div class="config-link-buttons">
                      <a class="settings-button" 
                         href="#" 
                         @click.prevent="importHiddify(); handleButtonFeedback($el, $el.innerHTML, `<svg class='bi' width='16' height='16'><use href='#cloud-check'></use></svg> <span>${translations[currentLang].enter}</span>`)">
                        <svg class="bi" width="16" height="16"><use href="#cloud-plus"></use></svg>
                        <span x-text="translations[currentLang].settings || 'تنظیمات'"></span>
                      </a>
                    </div>
                  </div>

                  <div class="config-link">
                    <div class="config-link-name">
                      <svg class="bi" width="16" height="16"><use href="#gear-fill"></use></svg>
                      <span x-text="translations[currentLang].singboxSettings"></span>
                    </div>
                    <div class="config-link-buttons">
                      <a class="settings-button" 
                         href="#" 
                         @click.prevent="importSingbox(); handleButtonFeedback($el, $el.innerHTML, `<svg class='bi' width='16' height='16'><use href='#cloud-check'></use></svg> <span>${translations[currentLang].enter}</span>`)">
                        <svg class="bi" width="16" height="16"><use href="#cloud-plus"></use></svg>
                        <span x-text="translations[currentLang].settings || 'تنظیمات'"></span>
                      </a>
                    </div>
                  </div>
                </div>
              </div>
              
              <div class="my-block-big">
                <span class="my-step-counter mb-3"></span>
                <h5 class="my-text-heading fw-semibold" x-text="translations[currentLang].connectAndUse"></h5>
                <p class="my-text-content mb-2" x-text="translations[currentLang].connectAndUseDesc"></p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
 
  <div class="modal qr-modal fade" id="qr-modal" tabindex="-1" aria-labelledby="qrModalLabel" 
       x-data="{ title: '' }" @show-qr-title.window="title = $event.detail">
    <div class="modal-dialog modal-dialog-centered">
      <div class="modal-content">
        <div class="modal-header">
          <h5 class="my-text-heading" id="qrModalLabel" x-text="title"></h5>
          <button type="button" class="modal-close-btn" data-bs-dismiss="modal">
            <span x-text="$store.app.translations[$store.app.currentLang].close"></span>
          </button>
        </div>
        <div class="modal-body">
          <div id="qr-canvas"></div>
        </div>
      </div>
    </div>
  </div>
</body>
</html>

EOF

echo "Full index.html created — ready for your manual HTML."

# ---------- Build & Start ----------
echo "[DONE] Building docker compose..."
cd "$BASE_DIR"
docker compose build --no-cache || true
docker compose up -d || true

sleep 3

echo "Testing endpoint..."
TEST_USER="test"
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${PANEL_DOMAIN}/emergency/${TEST_USER}" || echo "000")
echo " -> HTTP code: $HTTP_CODE"

echo "=== Installer finished ==="
exit 0
