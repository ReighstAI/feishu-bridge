# Feishu Bridge — Channels Edition

用飞书驱动一个**常驻的交互式 Claude Code 会话**。消息走订阅计费（不是 `claude -p` 的额度池），重启自恢复，支持全部 slash 命令。

适用：Mac 上跑 Claude Code，飞书（手机 / Windows / 任意端）当客户端。

---

## 这套是什么

```
launchd → bridge-launchd.sh → tmux「bridge」→ bridge-supervisor.sh
       → claude --channels plugin:lark@claude-code-lark → lark server ──WS──→ 飞书
```

- **消息**：飞书 → lark 插件 → 注入正在跑的会话 → Claude 用 reply 工具回飞书。订阅计费。
- **slash 命令**（`/compact` `/clear` `/model` `/effort` `/status` …）：插件拦截 → tmux send-keys 打进真 TUI。
- **`/new`**：回一张四模式卡（default / acceptEdits / plan / bypass），回数字 → 按所选模式重启会话。
- **持久化**：launchd 开机自启、崩溃自恢复。

## 前置（Mac）

- Claude Code 已安装并登录（用自己的订阅）
- `bun`、`tmux`（安装器没有会自动装；tmux 走 Homebrew）
- 自己的飞书机器人（App ID + Secret）。已经在用旧版 Python 桥的话，安装器会**自动复用**它的 `.env`，不用再填。

## 安装方式一：在终端跑（推荐给能开终端的人）

```bash
cd feishu-bridge
./install.sh
```

按提示走：缺凭据会问（能复用旧桥就不问）、问工作目录和默认模式、要一次管理员密码（写频道白名单）。

## 安装方式二：让 Claude Code 自己装（给非技术用户）

把下面整段**原样复制、发给那台 Mac 上的 Claude Code**（粘进对话框就行，不用改任何东西）。
它会自己跑完，只有两处需要你动手：① 中途复制两条 sudo 命令到终端（输开机密码）② 装完用飞书给机器人发第一条消息。

```
帮我在这台 Mac 上安装新版飞书桥（Channels 版）。请你自动执行下面的步骤，
只有需要我亲自做的地方（输管理员密码、提供飞书凭据）才停下来问我：

1. 装到 ~/feishu-bridge（已存在就更新）：
   git clone https://github.com/ReighstAI/feishu-bridge.git ~/feishu-bridge 2>/dev/null || (cd ~/feishu-bridge && git pull)
   然后 cd ~/feishu-bridge

2. 先不填凭据直接跑（安装器会自动找我旧版飞书桥的凭据复用）：
   BRIDGE_WORKDIR="$HOME" BRIDGE_MODE=bypassPermissions ./install.sh --auto
   —— 如果它报错「缺少飞书 App ID / Secret」，说明没找到旧凭据：这时问我要
   飞书 App ID（cli_ 开头）和 App Secret，拿到后重跑：
   LARK_APP_ID="<我给的ID>" LARK_APP_SECRET="<我给的Secret>" BRIDGE_WORKDIR="$HOME" BRIDGE_MODE=bypassPermissions ./install.sh --auto

3. 安装器会打印两条以 sudo 开头的命令（写频道白名单用）。把这两条命令
   原样显示给我，让我自己复制到终端运行——你绝对不要自己去跑 sudo。

4. 我说「sudo 跑完了」之后，你再按安装器打印的顺序执行那两行：
   先 ~/.feishu-bridge/bin/stop-old-bridge.sh（停掉我旧版飞书桥——一个机器人
   只能有一条连接，旧桥不停会和新桥互相吞消息），再 launchctl bootstrap 那行起新桥。

5. 跑 bash ~/.feishu-bridge/bin/verify.sh，要看到绿色 ✓「飞书已连接」才算成功；
   没连上就把输出给我看。

6. 成功后告诉我：我用飞书给机器人发一条消息就行——第一条消息会自动授权，
   不需要配对码。

完成后给我一句话总结（成功/卡在哪一步）。
```

> 默认装成：工作目录 = 你的用户主目录、权限模式 = bypassPermissions（手机端用最省事，不会卡在权限确认上）。要装到别的目录，把第 2 步的 `BRIDGE_WORKDIR="$HOME"` 改成那个目录的绝对路径。

## 首次使用：发一条消息就行

桥用 **trust-first-sender（首发自动授权）**：装好后你用飞书给机器人发的**第一条消息**会被自动授权并锁定为唯一用户，之后别人再发都会被拦。所以装完**尽快自己先发一条**，不需要配对码、不需要 `/lark:access`。

> 想换成更严格的模式（明确指定谁能用），把 `~/.claude/channels/lark/access.json` 的 `dmPolicy` 改成 `allowlist`、把允许的人填进 `allowFrom`。

## 日常管理

| 想做 | 命令 |
|---|---|
| 停桥 | `touch ~/.claude/channels/lark/stop` |
| 起桥 | `launchctl kickstart -k gui/$(id -u)/com.feishu-bridge.daemon` |
| 看日志 | `tail -f /tmp/feishu-bridge.log` |
| 改了配置/重启 | `launchctl kickstart -k gui/$(id -u)/com.feishu-bridge.daemon` |
| 升级到新版本 | `cd ~/feishu-bridge && git pull && ./install.sh --auto`（会复用现有凭据） |
| 卸载 | `./uninstall.sh`（加 `--purge` 连凭据+插件一起删） |

## 排查

- **发消息没反应（或时有时无）**：先看旧的 Python 桥是不是还在跑——一个机器人只能有一条连接，跑 `bash ~/.feishu-bridge/bin/stop-old-bridge.sh`。再看 `tail ~/.claude/channels/lark/server.log`：有 `failed to fetch bot info` 就是 App ID/Secret 不对，或飞书后台没开「长连接 / 事件订阅」。
- **装完一直完全没反应（不是时有时无，是从来不回），或重启后突然不回了**：旧版（≤0.9.0）在全新机器上可能卡在两个开机对话框——「是否信任此文件夹」和 bypass 模式警告——它们在频道连上之前就弹、手机端看不到也点不了，桥就一直连不上。0.9.1 起安装器会自动预批准这两个。升级修复：`cd ~/feishu-bridge && git pull && ./install.sh --auto`，再 `launchctl kickstart -k gui/$(id -u)/com.feishu-bridge.daemon` 重启一次验证。
- **每次重启弹「开发频道」警告框**：频道白名单（managed-settings.json）没写成。重跑安装器第 5 步的 sudo 命令。
- **`/model` 之类打开了选择器没反应**：少数命令会开交互选择器，send-keys 进得去但选不动——这类需要在终端里操作，属于已知边界。
