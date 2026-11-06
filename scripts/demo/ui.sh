#!/usr/bin/env bash
# Start (or restart) the one-screen demo control page on this host: http://localhost:8099
# Reach it from your laptop through the SSH tunnel (demo-tunnel.sh forwards 8099).
source "$(dirname "$0")/../lib.sh"
PIDF="$ROOT/.demo-ui.pid"
[[ -f "$PIDF" ]] && kill "$(cat "$PIDF")" 2>/dev/null || true
export PATH="$HOME/bin:$PATH"
[[ -z "${GH_TOKEN:-}" && -f "$HOME/.config/scn/gh-token" ]] && export GH_TOKEN="$(cat "$HOME/.config/scn/gh-token")"
setsid nohup python3 "$ROOT/demo-ui/server.py" > "$ROOT/.demo-ui.log" 2>&1 < /dev/null &
echo $! > "$PIDF"
sleep 2; curl -fsS -o /dev/null http://127.0.0.1:8099/ && ok "demo UI on http://localhost:8099 (log: .demo-ui.log)" || die "demo UI failed to start, see .demo-ui.log"
