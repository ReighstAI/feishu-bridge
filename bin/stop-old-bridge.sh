#!/bin/bash
# Stop & disable any old Python feishu bridge (feishu-claude-code) so it can't
# fight the new bridge for the Feishu WebSocket (one app = one connection).
# Idempotent, safe to re-run. Disables by renaming the plist — never deletes,
# so the old bridge can be restored by renaming back and bootstrapping.
set -uo pipefail

found=0
for plist in "$HOME"/Library/LaunchAgents/*.plist; do
  [ -f "$plist" ] || continue
  if grep -q "feishu-claude-code" "$plist" 2>/dev/null; then
    found=1
    label="$(basename "$plist" .plist)"
    echo "停用旧桥：$label"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
    mv "$plist" "$plist.disabled"
  fi
done
if pkill -f "feishu-claude-code" 2>/dev/null; then
  echo "已停掉仍在跑的旧桥进程"
fi
if [ "$found" = 1 ]; then
  echo "✓ 旧桥已停（plist 改名为 .disabled，要恢复就改回去重新 bootstrap）"
else
  echo "（没发现旧桥的 launchd 配置，跳过）"
fi
exit 0
