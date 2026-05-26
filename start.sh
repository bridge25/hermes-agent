#!/bin/bash
# Railway / generic container start script for Hermes gateway.
#
# Responsibilities:
#   1. Materialize HERMES_HOME from env vars (config.yaml, .env, auth.json)
#   2. Export the provider env vars that gateway/run.py:_resolve_runtime_agent_kwargs
#      reads in headless mode (HERMES_PROVIDER + matching <PROVIDER>_API_KEY)
#   3. Activate the venv baked into the upstream Docker image at /opt/hermes/.venv
#   4. Set the Telegram webhook (idempotent)
#   5. Start a separate healthcheck server on $PORT (default 3000) so Railway
#      can mark the container healthy without colliding with the Telegram
#      webhook port (8080)
#   6. exec hermes gateway run as PID 1 of the userland process tree
#
# This script assumes the following Railway env vars are set:
#   - HERMES_HOME (recommend: /tmp/hermes — avoids volume mount races)
#   - HERMES_PROVIDER=opencode-go
#   - HERMES_MODEL=kimi-k2.6
#   - OPENCODE_GO_API_KEY=<key>
#   - TELEGRAM_BOT_TOKEN=<token>
#   - TELEGRAM_WEBHOOK_URL=https://<railway-domain>/telegram
#   - TELEGRAM_WEBHOOK_SECRET=<secret>
#   - TELEGRAM_ALLOW_ALL_USERS=true
#   - PORT=3000 (healthcheck, not webhook)
#   - HERMES_AUTH_JSON_BOOTSTRAP=<auth.json contents as a single line>
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/tmp/hermes}"
INSTALL_DIR="/opt/hermes"
HERMES_MODEL_DEFAULT="${HERMES_MODEL:-kimi-k2.6}"
OPENCODE_GO_BASE_URL_DEFAULT="${OPENCODE_GO_BASE_URL:-https://opencode.ai/zen/go/v1}"

echo "[start.sh] HERMES_HOME=$HERMES_HOME  INSTALL_DIR=$INSTALL_DIR"

# --- 1. Directories ---------------------------------------------------------
mkdir -p \
  "$HERMES_HOME"/cron \
  "$HERMES_HOME"/sessions \
  "$HERMES_HOME"/logs \
  "$HERMES_HOME"/hooks \
  "$HERMES_HOME"/memories \
  "$HERMES_HOME"/skills \
  "$HERMES_HOME"/skins \
  "$HERMES_HOME"/plans \
  "$HERMES_HOME"/workspace \
  "$HERMES_HOME"/home \
  "$HERMES_HOME"/.hermes

# --- 2. .env (read by hermes_cli on import) ---------------------------------
cat > "$HERMES_HOME/.env" <<EOF
HERMES_HOME=$HERMES_HOME
HERMES_PROVIDER=opencode-go
HERMES_INFERENCE_PROVIDER=opencode-go
HERMES_MODEL=$HERMES_MODEL_DEFAULT
OPENCODE_GO_API_KEY=${OPENCODE_GO_API_KEY:-}
OPENCODE_GO_BASE_URL=$OPENCODE_GO_BASE_URL_DEFAULT
OPENAI_API_KEY=${OPENCODE_GO_API_KEY:-}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_ALLOW_ALL_USERS=${TELEGRAM_ALLOW_ALL_USERS:-true}
EOF
chmod 600 "$HERMES_HOME/.env"

# --- 3. config.yaml (model.provider is gateway's canonical source) ----------
cat > "$HERMES_HOME/config.yaml" <<YAML
model:
  default: $HERMES_MODEL_DEFAULT
  provider: opencode-go
  base_url: $OPENCODE_GO_BASE_URL_DEFAULT
YAML

# --- 4. auth.json (bootstrap from env, optional) ----------------------------
if [ -n "${HERMES_AUTH_JSON_BOOTSTRAP:-}" ]; then
  printf '%s' "$HERMES_AUTH_JSON_BOOTSTRAP" > "$HERMES_HOME/auth.json"
  chmod 600 "$HERMES_HOME/auth.json"
  echo "[start.sh] wrote auth.json from HERMES_AUTH_JSON_BOOTSTRAP"
fi

# --- 5. Exports inherited by child processes (gateway, webhook handler) -----
export HERMES_HOME
export HERMES_PROVIDER=opencode-go
export HERMES_INFERENCE_PROVIDER=opencode-go
export HERMES_MODEL="$HERMES_MODEL_DEFAULT"
export OPENCODE_GO_BASE_URL="$OPENCODE_GO_BASE_URL_DEFAULT"
export HERMES_ALLOW_ROOT_GATEWAY=1

# --- 6. Activate venv -------------------------------------------------------
# shellcheck source=/dev/null
source "$INSTALL_DIR/.venv/bin/activate"

# --- 7. Telegram webhook setup (idempotent) ---------------------------------
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_WEBHOOK_URL:-}" ]; then
  echo "[start.sh] setting Telegram webhook to $TELEGRAM_WEBHOOK_URL"
  curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
       -H "Content-Type: application/json" \
       -d "{\"url\":\"${TELEGRAM_WEBHOOK_URL}\",\"secret_token\":\"${TELEGRAM_WEBHOOK_SECRET:-}\",\"drop_pending_updates\":true}" \
       > /dev/null \
       || echo "[start.sh] WARN: webhook setup failed (will retry on next deploy)"
fi

# --- 8. Provider resolution probe (gateway's exact code path) ---------------
python3 - <<'PYEOF' || echo "[start.sh] WARN: runtime provider probe raised"
import os
from hermes_cli.runtime_provider import resolve_runtime_provider
runtime = resolve_runtime_provider()
print(
    f"[start.sh] runtime provider: {runtime.get('provider')} | "
    f"base_url: {runtime.get('base_url')} | "
    f"api_key present: {bool(runtime.get('api_key'))} | "
    f"HERMES_PROVIDER env: {os.getenv('HERMES_PROVIDER')!r}",
    flush=True,
)
PYEOF

# --- 9. Healthcheck server (background, separate PORT from webhook) ---------
HEALTH_PORT="${PORT:-3000}"
python3 - "$HEALTH_PORT" <<'PYEOF' &
import sys, http.server, socketserver
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/", "/health", "/healthz"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a, **kw):
        pass
with socketserver.TCPServer(("", port), H) as s:
    s.serve_forever()
PYEOF

echo "[start.sh] healthcheck on :$HEALTH_PORT — handing off to hermes gateway run"

# --- 10. exec gateway as the foreground process -----------------------------
exec hermes gateway run
