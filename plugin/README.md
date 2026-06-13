# Lark (Larksuite / Feishu)

[日本語版はこちら](./README.ja.md)

Connect a Lark bot to your Claude Code with an MCP server.

When the bot receives a message, the MCP server forwards it to Claude and provides tools to reply, react, and edit messages. Supports both **Lark** (international) and **Feishu** (China).

## For LLMs

If you're an AI assistant helping a user install this plugin, see [llms.md](./llms.md) for automated installation instructions.

## Prerequisites

- [Bun](https://bun.sh) — the MCP server runs on Bun. Install with `curl -fsSL https://bun.sh/install | bash`.

## Quick Setup

> Default pairing flow for a single-user DM bot. See [ACCESS.md](./ACCESS.md) for groups and multi-user setups.

**1. Create a Lark application and bot.**

Go to the [Lark Open Platform](https://open.larksuite.com/app) (or [Feishu Open Platform](https://open.feishu.cn/app) for China) and click **Create Custom App**. Give it a name.

Navigate to **Features** → **Bot** and enable the bot capability.

**2. Configure permissions.**

Go to **Permissions & Scopes** and add the following:

- `im:message` — Read and send direct messages and group chat messages
- `im:message:readonly` — Read direct messages and group chat messages
- `im:message:send_as_bot` — Send messages as an app
- `im:message.group_at_msg:readonly` — Obtain group messages mentioning the bot
- `im:message.group_msg` — Read all messages in group chats (required for `fetch_messages` in groups)
- `im:message.p2p_msg:readonly` — Get direct messages sent to bot
- `im:resource` — Read and upload images or other files
- `im:chat` — Obtain and update group information
- `im:chat:readonly` — Obtain group information

Publish a version and approve it (self-built apps need tenant admin approval).

**3. Enable event subscription.**

Go to **Events & Callbacks** → **Event Configuration**:
- Select **"Receive events through persistent connection"** (recommended)
- Click **Add Events** and add: `im.message.receive_v1` (Receive messages)
- Save

No public URL, encryption, or webhook setup needed — the SDK handles everything via WebSocket.

**4. Get app credentials.**

Go to **Credentials & Basic Info**. Copy the **App ID** and **App Secret**.

**5. Install the plugin.**

```bash
git clone https://github.com/MocA-Love/claude-code-lark.git
claude plugin marketplace add /path/to/claude-code-lark
claude plugin install lark@claude-code-lark
```

**6. Give the server the credentials.**

```
/lark:configure cli_xxxx your_app_secret_here
```

Writes `LARK_APP_ID=...` and `LARK_APP_SECRET=...` to `~/.claude/channels/lark/.env`.

**7. Relaunch with the channel flag.**

Exit your session and start a new one:

```sh
claude --dangerously-load-development-channels plugin:lark@claude-code-lark
```

**8. Pair.**

With Claude Code running, DM your bot on Lark — it replies with a pairing code. In your Claude Code session:

```
/lark:access pair <code>
```

Your next DM reaches the assistant.

**9. Lock it down.**

Pairing is for capturing IDs. Once you're in, switch to `allowlist`:

```
/lark:access policy allowlist
```

## Feishu (China) Setup

For Feishu instead of Lark, set the domain:

```
/lark:configure domain open.feishu.cn
```

This changes the API base URL from `open.larksuite.com` to `open.feishu.cn`.

## Access control

See **[ACCESS.md](./ACCESS.md)** for DM policies, group chats, mention detection, delivery config, skill commands, and the `access.json` schema.

Quick reference: IDs are Lark **open_id** values (e.g., `ou_xxxx`) for users and **chat_id** values (e.g., `oc_xxxx`) for chats. Default policy is `pairing`. Group chats are opt-in per chat_id.

## Tools exposed to the assistant

| Tool | Purpose |
| --- | --- |
| `reply` | Send to a chat. Takes `chat_id` + `text`, optionally `reply_to` (message_id) for threading and `files` (absolute paths) for attachments. Images send as Lark image messages; other files as documents. Auto-chunks; returns sent message ID(s). |
| `react` | Add an emoji reaction to any message by ID. Use Lark emoji type names (THUMBSUP, HEART, SMILE, etc). |
| `edit_message` | Edit a message the bot previously sent. Only works on the bot's own messages. |
| `fetch_messages` | Pull recent history from a chat (oldest-first). Max 50 per call. Each line includes the message ID. |
| `download_attachment` | Download image or file from a specific message by ID to `~/.claude/channels/lark/inbox/`. Returns file paths + metadata. |

## Environment variables

All set in `~/.claude/channels/lark/.env`:

| Variable | Required | Description |
| --- | --- | --- |
| `LARK_APP_ID` | Yes | App ID from Developer Console (starts with `cli_`) |
| `LARK_APP_SECRET` | Yes | App Secret from Developer Console |
| `LARK_DOMAIN` | No | API domain. Default: `open.larksuite.com`. Use `open.feishu.cn` for Feishu. |
| `LARK_ACCESS_MODE` | No | Set to `static` to freeze access config at boot. |

## Architecture

```
User (Lark) → Lark Cloud ←WebSocket→ Lark SDK (WSClient)
                                          ↓
                                    MCP Server ←stdio→ Claude Code
                                          ↓
                                    Lark REST API → User (Lark)
```

No public URL needed. The SDK maintains a persistent WebSocket connection to Lark's servers.

## Multiple sessions and `/lark:takeover`

Only one Claude Code session can receive Lark messages at a time. The plugin uses a lock file (`~/.claude/channels/lark/ws.lock`) to ensure exclusive WebSocket connection — the first session to start acquires the lock, and others skip connecting.

To switch the Lark connection to a different session, run in the target session:

```
/lark:takeover
```

To check which sessions are running and who holds the lock:

```
/lark:takeover status
```

Each plugin process registers itself in `~/.claude/channels/lark/sessions/` with its PID, working directory, and start time. The takeover skill reads this registry to identify sessions instantly — no process tree traversal needed.

The previous session releases the connection within ~3 seconds, and the current session takes over. This is useful when you want to continue work from your phone via Lark — switch to the session you're working on, and Lark messages will reach it with full context.

### Zombie connections

If a session is killed with `kill -9` (SIGKILL), the lock and session files may be stale. Other sessions automatically detect dead processes and clean up. You can also manually clean up:

```bash
# List running Lark plugin processes
ps aux | grep "bun.*server.ts" | grep -v grep

# Kill zombie processes
kill <pid>
```

## Development

### Plugin cache

Claude Code caches installed plugins at `~/.claude/plugins/cache/`. When developing locally, changes to source files are **not automatically reflected**. Clear the cache after each change:

```bash
rm -rf ~/.claude/plugins/cache/claude-code-lark/
```

Then restart your Claude Code session.

## License

Apache-2.0
