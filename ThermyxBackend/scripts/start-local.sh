#!/bin/bash
# Runs the Thermyx relay on this Mac, with a free public HTTPS address.
#
#   ./scripts/start-local.sh           start (or reuse) the relay and tunnel
#   ./scripts/start-local.sh stop      stop both
#
# Texting is forced OFF here, whatever .env says, until the A2P registration
# is approved. Needs: node 22.5+, cloudflared (brew install cloudflared).
set -euo pipefail

cd "$(dirname "$0")/.."
PORT="${PORT:-8787}"
LOG_DIR="data/logs"
mkdir -p data "$LOG_DIR"

if [[ "${1:-}" == "stop" ]]; then
  pkill -f "cloudflared tunnel --url http://localhost:$PORT" 2>/dev/null || true
  pkill -f "node.*server.js" 2>/dev/null || true
  echo "Stopped the relay and the tunnel."
  exit 0
fi

command -v cloudflared >/dev/null || { echo "Install the tunnel first: brew install cloudflared"; exit 1; }

if curl -fs -m 3 "http://localhost:$PORT/health" >/dev/null 2>&1; then
  echo "Relay already running on port $PORT."
else
  SMS_ENABLED=false PORT="$PORT" DATABASE_FILE=./data/thermyx.sqlite \
    nohup node --disable-warning=ExperimentalWarning server.js >"$LOG_DIR/relay.log" 2>&1 &
  for _ in $(seq 1 20); do
    curl -fs -m 2 "http://localhost:$PORT/health" >/dev/null 2>&1 && break
    sleep 0.5
  done
  curl -fs -m 2 "http://localhost:$PORT/health" >/dev/null || { echo "Relay failed to start. See $LOG_DIR/relay.log"; exit 1; }
  echo "Relay started on port $PORT."
fi

TUNNEL_LOG="$LOG_DIR/tunnel.log"
if ! pgrep -f "cloudflared tunnel --url http://localhost:$PORT" >/dev/null; then
  nohup cloudflared tunnel --url "http://localhost:$PORT" --no-autoupdate >"$TUNNEL_LOG" 2>&1 &
fi
URL=""
for _ in $(seq 1 40); do
  URL=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
  [[ -n "$URL" ]] && break
  sleep 0.5
done
[[ -n "$URL" ]] || { echo "The tunnel didn't give an address. See $TUNNEL_LOG"; exit 1; }

echo
echo "Relay address for the app:  $URL"
PUBLIC=000
for _ in $(seq 1 60); do
  PUBLIC=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$URL/health" || true)
  [[ "$PUBLIC" == "200" ]] && break
  sleep 1
done
echo "Public health check:        $PUBLIC  (200 = working)"
echo
echo "One-time wearer code (valid 10 minutes):"
node --disable-warning=ExperimentalWarning admin.js wearer-code
echo
echo "Keep this Mac awake and this terminal's background jobs running."
echo "Stop everything with: ./scripts/start-local.sh stop"
