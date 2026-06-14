#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Feishu Bridge (Channels edition) — installer
#
# Sets up the full bridge on a Mac: lark plugin + supervisor + launchd autostart,
# so Feishu messages drive a persistent interactive Claude Code session (billed
# on the subscription, not the -p credit pool). Reuses an existing Python-bridge
# .env for Feishu credentials if present.
#
# Usage:
#   ./install.sh            # interactive: prompts for missing values, does sudo
#   BRIDGE_WORKDIR=/path BRIDGE_MODE=acceptEdits ./install.sh --auto
#                           # non-interactive (e.g. driven by Claude Code); the
#                           # one sudo step is printed for you to run if needed.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

AUTO=0; [ "${1:-}" = "--auto" ] && AUTO=1
BUNDLE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$HOME/.feishu-bridge"
STATE_DIR="$HOME/.claude/channels/lark"
LABEL="com.feishu-bridge.daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MS_DIR="/Library/Application Support/ClaudeCode"
MS_FILE="$MS_DIR/managed-settings.json"
SESSION="bridge"

say(){ printf "\n\033[1m▶ %s\033[0m\n" "$*"; }
ok(){ printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn(){ printf "  \033[33m!\033[0m %s\n" "$*"; }
die(){ printf "  \033[31m✗ %s\033[0m\n" "$*"; exit 1; }
ask(){ # ask VAR "prompt" "default"  — in --auto, takes default/env without prompting
  local __var="$1" __prompt="$2" __def="${3:-}"; local __cur="${!__var:-}"
  if [ -n "$__cur" ]; then return; fi
  if [ "$AUTO" = 1 ]; then printf -v "$__var" '%s' "$__def"; return; fi
  read -r -p "  $__prompt${__def:+ [$__def]}: " __in; printf -v "$__var" '%s' "${__in:-$__def}"
}

# ── 0. prerequisites ─────────────────────────────────────────────────────────
say "0/7  检查前置依赖"
command -v claude >/dev/null || die "未安装 Claude Code，或不在 PATH。先安装并登录后重试。"
ok "claude $(claude --version 2>/dev/null | head -1)"
if ! command -v bun >/dev/null; then
  warn "未装 bun，正在安装…"; curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1
  export PATH="$HOME/.bun/bin:$PATH"
fi
command -v bun >/dev/null && ok "bun $(bun --version)" || die "bun 安装失败，手动装：curl -fsSL https://bun.sh/install | bash"
if ! command -v tmux >/dev/null; then
  if command -v brew >/dev/null; then warn "未装 tmux，正在安装…"; brew install tmux >/dev/null 2>&1
  else die "需要 tmux，但这台机器没装 Homebrew。先装 Homebrew (https://brew.sh)，再 brew install tmux，然后重跑本安装器。"; fi
fi
command -v tmux >/dev/null && ok "tmux $(tmux -V)" || die "tmux 安装失败，手动跑 brew install tmux 后重试。"

# ── 1. Feishu credentials (reuse old bridge .env if present) ─────────────────
say "1/7  配置飞书凭据"
mkdir -p "$STATE_DIR"
APP_ID="${LARK_APP_ID:-}"; APP_SECRET="${LARK_APP_SECRET:-}"
if [ -z "$APP_ID" ] || [ -z "$APP_SECRET" ]; then
  OLD_ENV="$(find "$HOME" -maxdepth 5 -path '*feishu-claude-code/.env' 2>/dev/null | head -1)"
  if [ -n "$OLD_ENV" ]; then
    APP_ID="$(grep -E '^FEISHU_APP_ID=' "$OLD_ENV" | head -1 | cut -d= -f2- | tr -d '"'"'"' \r')"
    APP_SECRET="$(grep -E '^FEISHU_APP_SECRET=' "$OLD_ENV" | head -1 | cut -d= -f2- | tr -d '"'"'"' \r')"
    [ -n "$APP_ID" ] && ok "复用旧桥凭据：$OLD_ENV"
  fi
fi
ask APP_ID "飞书 App ID (cli_...)"
ask APP_SECRET "飞书 App Secret"
[ -n "$APP_ID" ] && [ -n "$APP_SECRET" ] || die "缺少飞书 App ID / Secret。"
ask LARK_DOMAIN "飞书域名" "open.feishu.cn"
# Normalize to one of the two values server.ts matches exactly — a stray value
# (trailing space, www., wrong tld) would silently route to the wrong endpoint.
case "$LARK_DOMAIN" in
  *larksuite*) LARK_DOMAIN="open.larksuite.com" ;;
  *) LARK_DOMAIN="open.feishu.cn" ;;
esac
cat > "$STATE_DIR/.env" <<EOF
LARK_APP_ID=$APP_ID
LARK_APP_SECRET=$APP_SECRET
LARK_DOMAIN=$LARK_DOMAIN
EOF
chmod 600 "$STATE_DIR/.env"; ok ".env 写好（app=$APP_ID）"

if [ ! -f "$STATE_DIR/access.json" ]; then
  # trust-first-sender: the first person to DM the bot is auto-approved and
  # pinned; everyone after is dropped. For a single-owner bot this skips the
  # pairing-code dance entirely — just send the first message after install.
  cat > "$STATE_DIR/access.json" <<'EOF'
{ "dmPolicy": "trust-first-sender", "allowFrom": [], "groups": {}, "ackReaction": "THUMBSUP", "replyToMode": "first", "textChunkLimit": 4000, "chunkMode": "newline" }
EOF
  ok "access.json：首发自动配对（你发的第一条消息自动获授权，无需批准码）"
else
  ok "access.json 已存在，保留"
fi

# Bridge-only settings:
#  - enableAllProjectMcpServers: auto-approve project MCP servers so non-bypass
#    launches don't hang at the MCP-discovery prompt (fires before the channel
#    server is up, so the bridge can't surface it).
#  - skipDangerousModePermissionPrompt: bypassPermissions mode shows a one-time
#    "Bypass Permissions" warning at launch; it fires before the channel is up,
#    so a headless launchd reboot would deadlock on it with nobody to dismiss it.
#    Pre-accept it. Loaded at boot via --settings, same path as the line above.
#  - permissions.allow: pre-allow the bridge's OWN Feishu tools (reply/react/…)
#    — they only message the owner, zero risk, and must never prompt or the
#    session freezes when it tries to reply in a non-bypass mode.
cat > "$STATE_DIR/bridge-settings.json" <<'EOF'
{
  "enableAllProjectMcpServers": true,
  "skipDangerousModePermissionPrompt": true,
  "permissions": {
    "allow": [
      "mcp__plugin_lark_lark__reply",
      "mcp__plugin_lark_lark__react",
      "mcp__plugin_lark_lark__edit_message",
      "mcp__plugin_lark_lark__fetch_messages",
      "mcp__plugin_lark_lark__download_attachment"
    ]
  }
}
EOF
ok "bridge-settings.json：自动批准项目 MCP + 跳过 bypass 警告 + 预授权飞书回复工具（非 bypass 不卡）"

# ── 2. working dir + bridge.conf ─────────────────────────────────────────────
say "2/7  工作目录与默认模式"
# Re-running to upgrade? Reuse the saved choices as defaults so an upgrade never
# silently resets workdir/mode. Without this, the README's bare `./install.sh
# --auto` upgrade falls back to the built-in acceptEdits and flips a
# bypassPermissions bridge. Precedence: an explicit env var still wins (ask()
# honors an already-set var before the default); the saved value beats the
# built-in fallback. Read in a subshell so sourcing the conf can't clobber an env
# var the caller passed.
PREV_WORKDIR=""; PREV_MODE=""
if [ -f "$STATE_DIR/bridge.conf" ]; then
  PREV_WORKDIR="$(. "$STATE_DIR/bridge.conf" 2>/dev/null; printf '%s' "${BRIDGE_WORKDIR:-}")"
  PREV_MODE="$(. "$STATE_DIR/bridge.conf" 2>/dev/null; printf '%s' "${BRIDGE_DEFAULT_MODE:-}")"
  [ -n "$PREV_WORKDIR" ] && ok "复用上次配置：workdir=$PREV_WORKDIR mode=${PREV_MODE:-acceptEdits}"
fi
ask BRIDGE_WORKDIR "桥的工作目录" "${PREV_WORKDIR:-$HOME}"
ask BRIDGE_MODE "默认权限模式 (acceptEdits/plan/default/bypassPermissions)" "${PREV_MODE:-acceptEdits}"
[ -d "$BRIDGE_WORKDIR" ] || die "工作目录不存在：$BRIDGE_WORKDIR"
cat > "$STATE_DIR/bridge.conf" <<EOF
BRIDGE_WORKDIR="$BRIDGE_WORKDIR"
BRIDGE_DEFAULT_MODE="$BRIDGE_MODE"
BRIDGE_PLUGIN="lark@claude-code-lark"
BRIDGE_TMUX_SESSION="$SESSION"
EOF
ok "bridge.conf：workdir=$BRIDGE_WORKDIR mode=$BRIDGE_MODE"

# Pre-clear the workspace-trust dialog for the workdir. The bridge runs claude
# headlessly via launchd, and the "Do you trust the files in this folder?" prompt
# fires at startup BEFORE the channel connects — with nobody at the terminal to
# answer it, the bridge deadlocks (silent "messages get no response", and again
# on every reboot). There is NO CLI flag to skip it for an interactive session
# (only -p/non-interactive skips it), so the only fix is to mark the folder
# trusted in ~/.claude.json — exactly what clicking "Yes, I trust this folder"
# writes. Atomic temp+rename so a concurrent claude can never read a half-written
# file; merge-safe so all other claude.json state is preserved.
CJSON="$HOME/.claude.json"
if [ -f "$CJSON" ]; then
  CJSON_PATH="$CJSON" TRUST_DIR="$BRIDGE_WORKDIR" bun -e '
    const fs = require("fs");
    const p = process.env.CJSON_PATH, w = process.env.TRUST_DIR;
    let d; try { d = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { process.exit(3); }
    if (!d.projects || typeof d.projects !== "object") d.projects = {};
    if (!d.projects[w] || typeof d.projects[w] !== "object") d.projects[w] = {};
    d.projects[w].hasTrustDialogAccepted = true;
    const tmp = p + ".tmp." + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(d, null, 2));
    fs.renameSync(tmp, p);
  ' && ok "已预批准工作目录信任（开机不会卡在「是否信任此文件夹」确认框）" \
    || warn "预批准信任失败（claude.json 解析异常）；首次启动可能弹一次信任框，到终端按 1 即可。"
else
  warn "未找到 ~/.claude.json（Claude 还没登录过？）；首次启动可能弹信任框，到终端按 1 即可。"
fi

# ── 3. install scripts ───────────────────────────────────────────────────────
say "3/7  安装脚本"
mkdir -p "$SCRIPTS_DIR/bin"
cp "$BUNDLE/bin/bridge-supervisor.sh" "$BUNDLE/bin/bridge-launchd.sh" "$BUNDLE/bin/stop-old-bridge.sh" "$BUNDLE/verify.sh" "$SCRIPTS_DIR/bin/"
chmod +x "$SCRIPTS_DIR/bin/"*.sh
ok "→ $SCRIPTS_DIR/bin/"

# ── 4. install the lark plugin (local scope, in the workdir) ─────────────────
say "4/7  安装 lark 插件"
claude plugin marketplace add "$BUNDLE/plugin" >/dev/null 2>&1 || warn "marketplace add 可能已存在"
( cd "$BRIDGE_WORKDIR" && claude plugin install -s local lark@claude-code-lark ) >/dev/null 2>&1 \
  && ok "插件已装（local 作用域，仅此工作目录启用）" || warn "插件安装返回非零，稍后用 /plugin 检查"

# ── 5. managed-settings allowlist (needs sudo, merge-safe) ───────────────────
say "5/7  频道白名单（需要一次管理员密码）"
MS_STAGE="$SCRIPTS_DIR/managed-settings.json"
# Build the channel allowlist with bun (guaranteed present from step 0). A fresh
# Mac may have no python3, and a silent python3 failure here would have written an
# empty allowlist → the channel would never enable. Merge-safe: keeps any existing
# managed settings, only adds our two keys. Guarded so an empty file is never copied.
MS_FILE_PATH="$MS_FILE" MS_OUT_PATH="$MS_STAGE" bun -e '
  const fs = require("fs");
  const p = process.env.MS_FILE_PATH, out = process.env.MS_OUT_PATH;
  let d = {};
  try { if (fs.existsSync(p)) d = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
  d.channelsEnabled = true;
  if (!Array.isArray(d.allowedChannelPlugins)) d.allowedChannelPlugins = [];
  if (!d.allowedChannelPlugins.some(x => x && x.marketplace === "claude-code-lark" && x.plugin === "lark"))
    d.allowedChannelPlugins.push({ marketplace: "claude-code-lark", plugin: "lark" });
  fs.writeFileSync(out, JSON.stringify(d, null, 2));
' || die "生成频道白名单失败（bun 执行出错）"
[ -s "$MS_STAGE" ] || die "频道白名单文件为空，已中止——不会写入空文件覆盖系统设置。"
SUDO_OK=0
if sudo -n true 2>/dev/null; then
  sudo mkdir -p "$MS_DIR" && sudo cp "$MS_STAGE" "$MS_FILE" && SUDO_OK=1
elif [ "$AUTO" = 0 ]; then
  echo "  需要管理员密码写入频道白名单："
  if sudo mkdir -p "$MS_DIR" && sudo cp "$MS_STAGE" "$MS_FILE"; then SUDO_OK=1; fi
fi
if [ "$SUDO_OK" = 1 ]; then ok "managed-settings 已写：$MS_FILE"
else
  warn "白名单这一步需要你手动跑（复制下面两行到终端，会让你输开机密码）："
  echo "      sudo mkdir -p \"$MS_DIR\""
  echo "      sudo cp \"$MS_STAGE\" \"$MS_FILE\""
  echo "    （这个文件在固定位置、不会被系统清理，随时可跑。）"
fi

# ── 6. launchd autostart ─────────────────────────────────────────────────────
say "6/7  开机自启 (launchd)"
mkdir -p "$(dirname "$PLIST")"
TOOLPATH="$(dirname "$(command -v bun)"):$(dirname "$(command -v claude)"):$(dirname "$(command -v tmux)")"
sed -e "s#__HOME__#$HOME#g" -e "s#__SCRIPTS__#$SCRIPTS_DIR/bin#g" -e "s#__WORKDIR__#$BRIDGE_WORKDIR#g" -e "s#__TOOLPATH__#$TOOLPATH#g" \
  "$BUNDLE/templates/feishu-bridge.plist.template" > "$PLIST"
ok "plist：$PLIST"
if [ "$SUDO_OK" = 1 ]; then
  # One Feishu app = one WebSocket. Stop the old Python bridge (if any) right
  # before starting the new one, or the two eat each other's messages.
  bash "$SCRIPTS_DIR/bin/stop-old-bridge.sh"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then ok "launchd 已加载，桥正在启动"
  else warn "bootstrap 返回非零，手动跑：launchctl bootstrap gui/\$(id -u) \"$PLIST\""; fi
else
  warn "白名单没写成前先不加载 launchd。写完白名单后，按顺序跑这几行（先停旧桥，再起新桥）："
  echo "      bash $SCRIPTS_DIR/bin/stop-old-bridge.sh"
  echo "      launchctl bootout gui/\$(id -u)/$LABEL 2>/dev/null"
  echo "      launchctl bootstrap gui/\$(id -u) \"$PLIST\""
fi

# ── 7. verify ────────────────────────────────────────────────────────────────
say "7/7  验证"
if [ "$SUDO_OK" = 1 ]; then
  bash "$SCRIPTS_DIR/bin/verify.sh" || warn "验证未全通过，按上面提示排查。"
else
  warn "白名单 + launchd 还没跑完，跳过验证。手动跑完那两步后执行：bash $SCRIPTS_DIR/bin/verify.sh"
fi

printf "\n\033[1m安装完成。\033[0m\n"
echo "下一步：用飞书给你的机器人发一条消息——就这一步。"
echo "  • 你发的第一条消息会被自动授权（trust-first-sender），不需要配对码、不需要 /lark:access。"
echo "  • 之后即可正常对话，支持 /compact /stop /clear /model /effort /status /new 等全部命令。"
echo
echo "管理命令："
echo "  停桥：  touch $STATE_DIR/stop"
echo "  起桥：  launchctl kickstart -k gui/\$(id -u)/$LABEL"
echo "  看日志：tail -f /tmp/feishu-bridge.log"
