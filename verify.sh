#!/bin/bash
# Verify the Feishu bridge is actually up AND authenticated. Safe anytime.
# Truthful check: the lark server prints "connected (bot: NAME)" only after it
# successfully fetched bot info (= creds valid), and "failed to fetch bot info"
# when creds are wrong. ws.lock existing is NOT proof of connection.
set -uo pipefail
# Homebrew/bun aren't always on an interactive (or agent-spawned) shell's PATH —
# without this, `tmux has-session` below false-fails on a healthy bridge.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.bun/bin:$PATH"
LABEL="com.feishu-bridge.daemon"
STATE_DIR="$HOME/.claude/channels/lark"
CONF="$STATE_DIR/bridge.conf"; [ -f "$CONF" ] && source "$CONF"
SESSION="${BRIDGE_TMUX_SESSION:-bridge}"
# The server appends connection events here itself — under tmux its stderr
# never reaches launchd's log files, so this is the only truthful signal.
LOG="$STATE_DIR/server.log"

ok(){ printf "  \033[32m✓\033[0m %s\n" "$*"; }
bad(){ printf "  \033[31m✗\033[0m %s\n" "$*"; }

echo "验证飞书桥（最多等 60 秒让它启动）…"
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running" \
  && ok "launchd 守护在运行" || bad "launchd 未运行（跑 launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/$LABEL.plist）"
tmux has-session -t "$SESSION" 2>/dev/null && ok "tmux 会话「$SESSION」存在" || bad "tmux 会话不存在（看 /tmp/feishu-bridge.log）"

# server.log is append-only across restarts — only trust entries from the last
# 5 minutes, so yesterday's success can't make today's dead bridge "pass".
CUTOFF="$(date -u -v-5M +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S)"
recent(){ awk -v c="$CUTOFF" '$1 >= c' "$LOG" 2>/dev/null; }

for _ in $(seq 1 30); do
  # Check failure FIRST: on bad creds the server logs "failed to fetch bot info"
  # and still logs a bare "connected" (no bot name) — failure must win the race.
  if recent | grep -q "failed to fetch bot info"; then
    bad "飞书鉴权失败 —— App ID/Secret 不对，或飞书后台没开「长连接/事件订阅」。看 $LOG"
    exit 1
  fi
  # Require a non-empty bot name in the parentheses — proof bot info was fetched.
  if recent | grep -qE "connected \(bot: [^)]+\)"; then
    BOT=$(recent | grep "connected (bot:" | tail -1 | sed -E 's/.*\(bot: ([^)]*)\).*/\1/')
    ok "飞书已连接（机器人：$BOT）"
    echo; echo "✅ 桥工作正常。用飞书给机器人发一条消息试试。"
    exit 0
  fi
  sleep 2
done
bad "60 秒内没看到连接成功 —— 看 $LOG 和 /tmp/feishu-bridge.log"
exit 1
