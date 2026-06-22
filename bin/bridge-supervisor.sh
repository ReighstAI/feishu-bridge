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
RESUME_FILE="$STATE_DIR/resume-session"
LAST_SESSION_FILE="$STATE_DIR/last-session"
STOP="$STATE_DIR/stop"

mkdir -p "$STATE_DIR"
rm -f "$STOP"
export LARK_TMUX_SESSION="$SESSION"   # so the lark server's send-keys hits this session
export LARK_BRIDGE=1                  # only this claude may hold the Feishu WS; other sessions stay dormant
export BRIDGE_WORKDIR="$WORKDIR"      # the PreToolUse destructive-op guard reads this to protect the workdir
cd "$WORKDIR" || { echo "[supervisor] workdir missing: $WORKDIR"; exit 1; }

# Durable auth for an unattended INTERACTIVE bridge. Interactive Claude Code ignores
# CLAUDE_CODE_OAUTH_TOKEN (only `claude -p` honors it) and falls through to keychain
# /login, which expires and 401s the bridge with no human to re-login. ANTHROPIC_AUTH_TOKEN
# (auth precedence #2, terminal sessions) IS honored interactively — point it at the
# long-lived `claude setup-token` token (sk-ant-oat01-…, subscription-billed, ~1yr).
# Missing file → falls back to keychain /login. Rotate yearly: re-run setup-token,
# overwrite the file, restart.
TOKEN_FILE="$STATE_DIR/oauth-token"
[ -s "$TOKEN_FILE" ] && export ANTHROPIC_AUTH_TOKEN="$(cat "$TOKEN_FILE")"

# --settings loads ADDITIONAL bridge-only settings (enableAllProjectMcpServers)
# so non-bypass launches don't hang at the project-MCP discovery prompt, which
# fires before the channel server is up and so can't be surfaced to Feishu.
COMMON=(--settings "$STATE_DIR/bridge-settings.json" --channels "plugin:$PLUGIN")

# Single-instance guard. `tmux kill-session` does NOT kill the claude inside — it
# orphans it: the old claude keeps the Feishu WS and keeps refreshing the shared
# keychain login, so multiple claudes rotate the refresh token and 401 each other.
# Kill any stray bridge claude before launching ours. Safe: launchd guarantees one
# supervisor, so an existing channel claude here is an orphan, never a peer we need.
pkill -9 -f "channels plugin:$PLUGIN" 2>/dev/null || true

echo "[supervisor] up (workdir=$WORKDIR, plugin=$PLUGIN)"
while true; do
  MODE="$(cat "$MODE_FILE" 2>/dev/null || echo "$DEFAULT_MODE")"
  case "$MODE" in default|acceptEdits|plan|bypassPermissions) ;; *) MODE="$DEFAULT_MODE" ;; esac

  # Resume the conversation across a relaunch, two ways:
  #   1. /mode keeps context: the lark server writes the bridge's session id to
  #      RESUME_FILE. Resume it ONCE on this relaunch, then delete it so a later
  #      crash-relaunch starts clean — a failed --resume self-heals to fresh next
  #      loop instead of looping on a bad id.
  #   2. crash-relaunch: the lark server persists an always-current session id to
  #      LAST_SESSION_FILE every turn. With no deliberate /mode resume pending, an
  #      unexpected exit (OOM/segfault/context overflow) resumes the conversation
  #      instead of losing it. NOT deleted — it's the live id, refreshed each turn.
  # The ${a[@]+"${a[@]}"} guard expands to nothing on an empty array (safe under
  # set -u on macOS's bash 3.2, where a bare "${a[@]}" on an empty array errors).
  RESUME_ARGS=()
  RID=""
  if [ -s "$RESUME_FILE" ]; then
    RID="$(cat "$RESUME_FILE" 2>/dev/null)"
    rm -f "$RESUME_FILE"
    [ -n "$RID" ] && RESUME_ARGS=(--resume "$RID")
  elif [ -s "$LAST_SESSION_FILE" ]; then
    RID="$(cat "$LAST_SESSION_FILE" 2>/dev/null)"
    [ -n "$RID" ] && RESUME_ARGS=(--resume "$RID")
  fi

  echo "[supervisor] launching claude (mode=$MODE${RID:+, resume=$RID})"
  if [ "$MODE" = bypassPermissions ]; then
    claude --dangerously-skip-permissions ${RESUME_ARGS[@]+"${RESUME_ARGS[@]}"} "${COMMON[@]}"
  else
    claude --permission-mode "$MODE" ${RESUME_ARGS[@]+"${RESUME_ARGS[@]}"} "${COMMON[@]}"
  fi

  if [ -f "$STOP" ]; then echo "[supervisor] stop file — exiting"; rm -f "$STOP"; break; fi
  echo "[supervisor] claude exited ($?). relaunch in 2s (stop: touch $STOP)"
  sleep 2
done
