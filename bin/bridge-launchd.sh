#!/bin/bash
# launchd wrapper — the persistence layer. Ensures a supervisor is alive inside
# tmux session $SESSION; recreates it on death/reboot. Two-layer ownership, no
# competing managers: this wrapper owns "supervisor exists", the supervisor owns
# "claude exists + /new". The wrapper only acts when the supervisor PROCESS is
# gone, which never happens during a /new relaunch — so they never race.
set -uo pipefail

STATE_DIR="$HOME/.claude/channels/lark"
CONF="$STATE_DIR/bridge.conf"
[ -f "$CONF" ] && source "$CONF"
SESSION="${BRIDGE_TMUX_SESSION:-bridge}"
SUPERVISOR="$HOME/.feishu-bridge/bin/bridge-supervisor.sh"
STOP="$STATE_DIR/stop"

mkdir -p "$STATE_DIR"
supervisor_alive() { pgrep -f "$HOME/.feishu-bridge/bin/bridge-supervisor.sh" >/dev/null 2>&1; }

echo "[wrapper] up (session=$SESSION, pid=$$)"

# Self-heal: disable/kill any old Python bridge before ours comes up, so a reboot
# can never put two bridges on the same Feishu WebSocket (one app = one connection).
# Renames any feishu-claude-code plist -> .disabled + pkills it; idempotent, safe.
bash "$HOME/.feishu-bridge/bin/stop-old-bridge.sh" 2>/dev/null || true

while true; do
  if [ -f "$STOP" ]; then
    echo "[wrapper] stop file — tearing down, exit 0"
    tmux kill-session -t "$SESSION" 2>/dev/null
    pkill -f "$HOME/.feishu-bridge/bin/bridge-supervisor.sh" 2>/dev/null
    rm -f "$STOP"
    exit 0
  fi
  if ! supervisor_alive; then
    echo "[wrapper] no supervisor — (re)creating tmux session $SESSION"
    tmux kill-session -t "$SESSION" 2>/dev/null
    tmux new-session -d -s "$SESSION" "bash '$SUPERVISOR'"
    sleep 8
  fi
  sleep 15
done
