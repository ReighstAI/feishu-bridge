#!/bin/bash
# Feishu bridge supervisor — owns the claude process. Loops claude (channels +
# lark plugin) in the permission mode named in launch-mode; /new relaunches it
# in a new mode; crash-relaunches otherwise. Runs INSIDE tmux (so /compact etc.
# can be typed into the real TUI via send-keys).
#
# All machine-specific values come from bridge.conf — this script is identical
# on every machine.
set -uo pipefail

STATE_DIR="$HOME/.claude/channels/lark"
CONF="$STATE_DIR/bridge.conf"
[ -f "$CONF" ] && source "$CONF"

WORKDIR="${BRIDGE_WORKDIR:-$HOME}"
DEFAULT_MODE="${BRIDGE_DEFAULT_MODE:-acceptEdits}"
PLUGIN="${BRIDGE_PLUGIN:-lark@claude-code-lark}"
SESSION="${BRIDGE_TMUX_SESSION:-bridge}"
MODE_FILE="$STATE_DIR/launch-mode"
STOP="$STATE_DIR/stop"

mkdir -p "$STATE_DIR"
rm -f "$STOP"
export LARK_TMUX_SESSION="$SESSION"   # so the lark server's send-keys hits this session
export LARK_BRIDGE=1                  # only this claude may hold the Feishu WS; other sessions stay dormant
cd "$WORKDIR" || { echo "[supervisor] workdir missing: $WORKDIR"; exit 1; }

# --settings loads ADDITIONAL bridge-only settings (enableAllProjectMcpServers)
# so non-bypass launches don't hang at the project-MCP discovery prompt, which
# fires before the channel server is up and so can't be surfaced to Feishu.
COMMON=(--settings "$STATE_DIR/bridge-settings.json" --channels "plugin:$PLUGIN")
echo "[supervisor] up (workdir=$WORKDIR, plugin=$PLUGIN)"
while true; do
  MODE="$(cat "$MODE_FILE" 2>/dev/null || echo "$DEFAULT_MODE")"
  case "$MODE" in default|acceptEdits|plan|bypassPermissions) ;; *) MODE="$DEFAULT_MODE" ;; esac

  echo "[supervisor] launching claude (mode=$MODE)"
  if [ "$MODE" = bypassPermissions ]; then
    claude --dangerously-skip-permissions "${COMMON[@]}"
  else
    claude --permission-mode "$MODE" "${COMMON[@]}"
  fi

  if [ -f "$STOP" ]; then echo "[supervisor] stop file — exiting"; rm -f "$STOP"; break; fi
  echo "[supervisor] claude exited ($?). relaunch in 2s (stop: touch $STOP)"
  sleep 2
done
