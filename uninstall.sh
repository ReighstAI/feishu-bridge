#!/bin/bash
# Remove the Feishu bridge (Channels edition). Leaves your .env/access.json and
# the lark plugin in place; pass --purge to remove those too.
set -uo pipefail
LABEL="com.feishu-bridge.daemon"
STATE_DIR="$HOME/.claude/channels/lark"

echo "停止并卸载 launchd…"
touch "$STATE_DIR/stop" 2>/dev/null
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
tmux kill-session -t bridge 2>/dev/null
pkill -f "$HOME/.feishu-bridge/bin/bridge-supervisor.sh" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/.feishu-bridge"
echo "✓ 桥已卸载。"

if [ "${1:-}" = "--purge" ]; then
  rm -f "$STATE_DIR/.env" "$STATE_DIR/access.json" "$STATE_DIR/bridge.conf" "$STATE_DIR/launch-mode"
  claude plugin uninstall lark@claude-code-lark 2>/dev/null
  echo "✓ 凭据 + 插件也已清除。"
fi
echo "注意：/Library/Application Support/ClaudeCode/managed-settings.json 的频道白名单未动（系统级，需 sudo 手动改）。"
