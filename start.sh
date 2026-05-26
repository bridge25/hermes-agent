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

# Debug: prove the container made it this far BEFORE any guard activates.
# These three lines must reach Railway's log stream; if they don't, the
# script never ran (e.g. permissions, missing /bin/bash, ENTRYPOINT issue).
echo "[start.sh] alive pid=$$ time=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[start.sh] user=$(id)"
echo "[start.sh] pwd=$(pwd) shell=$BASH_VERSION"

# Show every command after this point for traceability, then activate guards.
set -x
set -euo pipefail
trap 'echo "[start.sh] FAILED at line $LINENO (exit=$?)" >&2' ERR

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

# Railway routes all external HTTPS traffic to a single internal port
# (set via $PORT, default 3000). To receive Telegram webhook POSTs, the
# gateway must listen on that exact port — otherwise Railway forwards the
# Telegram POST to whatever else is on $PORT (e.g., a stand-alone
# healthcheck) and the bot never sees a single message.
export TELEGRAM_WEBHOOK_PORT="${PORT:-3000}"
echo "[start.sh] TELEGRAM_WEBHOOK_PORT pinned to PORT=$TELEGRAM_WEBHOOK_PORT"

# Explicitly re-export Railway-provided Telegram env vars so they are
# guaranteed to reach the python gateway process. Without this, if
# something between Railway and the container drops a variable, the
# gateway falls back to polling mode and deletes the webhook from
# Telegram's side — making it look like our setWebhook keeps "resetting"
# even though Telegram is doing exactly what gateway told it to.
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export TELEGRAM_WEBHOOK_URL="${TELEGRAM_WEBHOOK_URL:-}"
export TELEGRAM_WEBHOOK_SECRET="${TELEGRAM_WEBHOOK_SECRET:-}"
export TELEGRAM_ALLOW_ALL_USERS="${TELEGRAM_ALLOW_ALL_USERS:-true}"
export OPENCODE_GO_API_KEY="${OPENCODE_GO_API_KEY:-}"

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

# --- 7b. Webhook keepalive loop (background) --------------------------------
# python-telegram-bot's webhook code path repeatedly clears the webhook on
# Telegram's side during its application/updater retry cycles, even though
# our local HTTP listener stays up. To survive that, we run a background
# loop that re-sets the webhook every 25s if Telegram reports it as empty.
# Cost: one HTTP call per minute. Benefit: deterministic message delivery.
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_WEBHOOK_URL:-}" ]; then
  (
    # Wait for the gateway boot/PTB-init churn to settle a bit.
    sleep 30
    while true; do
      _info=$(curl -fsS -m 8 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo" 2>/dev/null || echo '{}')
      _cur=$(printf '%s' "$_info" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("result",{}).get("url",""))
except: print("")' 2>/dev/null)
      if [ -z "$_cur" ] || [ "$_cur" != "${TELEGRAM_WEBHOOK_URL}" ]; then
        curl -fsS -m 8 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
             -H "Content-Type: application/json" \
             -d "{\"url\":\"${TELEGRAM_WEBHOOK_URL}\",\"secret_token\":\"${TELEGRAM_WEBHOOK_SECRET:-}\",\"drop_pending_updates\":false}" \
             > /dev/null 2>&1 \
             && echo "[webhook-keepalive] re-armed (Telegram had: ${_cur:-empty})"
      fi
      sleep 25
    done
  ) &
  disown
  echo "[start.sh] webhook keepalive loop started (every 25s)"
fi

# --- 8. Provider resolution probe (gateway's exact code path) ---------------
python3 - <<'PYEOF' || echo "[start.sh] WARN: runtime provider probe raised"
import os
from hermes_cli.runtime_provider import resolve_runtime_provider
runtime = resolve_runtime_provider()
# Mask key but show enough to confirm it's truly set and matches sk- prefix
_k = os.getenv("OPENCODE_GO_API_KEY","")
_k_disp = f"{_k[:5]}…{_k[-4:]} ({len(_k)} chars)" if _k else "(MISSING)"
print(
    f"[start.sh] runtime provider: {runtime.get('provider')} | "
    f"base_url: {runtime.get('base_url')} | "
    f"api_key present: {bool(runtime.get('api_key'))} | "
    f"HERMES_PROVIDER env: {os.getenv('HERMES_PROVIDER')!r}",
    flush=True,
)
print(
    f"[start.sh] telegram env check | "
    f"TELEGRAM_WEBHOOK_URL: {os.getenv('TELEGRAM_WEBHOOK_URL','(EMPTY)')!r} | "
    f"TELEGRAM_WEBHOOK_PORT: {os.getenv('TELEGRAM_WEBHOOK_PORT','(EMPTY)')!r} | "
    f"TELEGRAM_WEBHOOK_SECRET len: {len(os.getenv('TELEGRAM_WEBHOOK_SECRET',''))} | "
    f"TELEGRAM_BOT_TOKEN len: {len(os.getenv('TELEGRAM_BOT_TOKEN',''))} | "
    f"OPENCODE_GO_API_KEY: {_k_disp}",
    flush=True,
)
PYEOF

# --- 9. (removed) standalone healthcheck server ----------------------------
# Earlier versions launched a Python HTTP server here so Railway could see
# the container as alive. That collided with the Telegram webhook listener
# (both binding $PORT) and silently swallowed every Telegram POST. The
# gateway's webhook server already listens on the same $PORT — and Railway
# is configured with healthcheckPath=null, so an external probe isn't
# required. Kept the section header so the file structure stays stable
# for anyone diffing against the previous version.

echo "[start.sh] handing off to hermes gateway run (webhook port=$TELEGRAM_WEBHOOK_PORT)"

# --- 10. exec gateway as the foreground process -----------------------------
exec hermes gateway run
