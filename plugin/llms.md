# claude-code-lark — LLM Installation Guide

This file is designed for LLMs (Claude Code, Cursor, Windsurf, etc.) to automatically install and configure the Lark channel plugin.

## What this plugin does

Connects a Lark (Larksuite/Feishu) bot to Claude Code via WebSocket long connection. Messages sent to the bot on Lark are forwarded to the Claude Code session, and the assistant can reply back through Lark.

## Automated Installation Steps

Run the following commands in order:

### 1. Clone the repository

```bash
git clone https://github.com/MocA-Love/claude-code-lark.git ~/claude-code-lark
```

### 2. Register as a local marketplace

```bash
claude plugin marketplace add ~/claude-code-lark
```

### 3. Install the plugin

```bash
claude plugin install lark@claude-code-lark
```

### 4. Configure credentials

The user must provide their Lark App ID and App Secret. These are obtained from the [Lark Open Platform Developer Console](https://open.larksuite.com/app).

```bash
mkdir -p ~/.claude/channels/lark
cat > ~/.claude/channels/lark/.env << 'EOF'
LARK_APP_ID=<user_provided_app_id>
LARK_APP_SECRET=<user_provided_app_secret>
EOF
chmod 600 ~/.claude/channels/lark/.env
```

For Feishu (China), also add:
```
LARK_DOMAIN=open.feishu.cn
```

### 5. Launch with channel flag

```bash
claude --dangerously-load-development-channels plugin:lark@claude-code-lark
```

## Lark App Prerequisites (User must do manually)

Before the plugin can work, the user needs to create a Lark app:

1. Go to [Lark Open Platform](https://open.larksuite.com/app) → Create Custom App
2. Enable **Bot** under Features
3. Add permissions: `im:message`, `im:message:readonly`, `im:message:send_as_bot`, `im:message.group_at_msg:readonly`, `im:message.group_msg`, `im:message.p2p_msg:readonly`, `im:resource`, `im:chat`, `im:chat:readonly`
4. Under **Events & Callbacks** → Event Configuration:
   - Select **"Receive events through persistent connection"**
   - Add event: `im.message.receive_v1`
5. Publish and approve the app version
6. Copy **App ID** (`cli_xxx`) and **App Secret** from Credentials & Basic Info

## After First Launch

Once the channel is running, the user should:

1. DM the bot on Lark → receive a pairing code
2. Run `/lark:access pair <code>` in the Claude Code session
3. Run `/lark:access policy allowlist` to lock down access

## File Structure

```
claude-code-lark/
├── .claude-plugin/
│   ├── plugin.json          # Plugin metadata
│   └── marketplace.json     # Marketplace definition
├── skills/
│   ├── configure/SKILL.md   # /lark:configure skill
│   ├── access/SKILL.md      # /lark:access skill
│   └── takeover/SKILL.md    # /lark:takeover skill (switch Lark connection between sessions)
├── .mcp.json                # MCP server configuration
├── server.ts                # Main MCP server (Bun + Lark SDK)
├── package.json             # Dependencies
├── ACCESS.md                # Access control documentation
├── README.md                # English documentation
└── README.ja.md             # Japanese documentation
```

## Troubleshooting

| Issue | Solution |
| --- | --- |
| "LARK_APP_ID and LARK_APP_SECRET required" | Set credentials in `~/.claude/channels/lark/.env` |
| Bot doesn't respond to DMs | Check that `im:message.p2p_msg` permission is added and app version is published |
| "chat is not allowlisted" | Run `/lark:access pair <code>` first, or `/lark:access allow <open_id>` |
| WebSocket connection fails | Verify App ID/Secret are correct and the app is published |
| "skipped (another session holds the lock)" | Another Claude Code session already has the Lark connection. Run `/lark:takeover` to switch it to this session |
| `fetch_messages` returns HTTP 400 in groups | Add `im:message.group_msg` permission in Developer Console and republish the app |
