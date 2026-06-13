---
name: configure
description: Set up the Lark channel — save the app credentials and review access policy. Use when the user asks to configure Lark, provides app credentials, asks "how do I set this up" or "who can reach me," or wants to check channel status.
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Bash(ls *)
  - Bash(mkdir *)
---

# /lark:configure — Lark Channel Setup

Writes the Lark app credentials to `~/.claude/channels/lark/.env` and orients the
user on access policy. The server reads the file at boot.

Arguments passed: `$ARGUMENTS`

---

## Dispatch on arguments

### No args — status and guidance

Read both state files and give the user a complete picture:

1. **Credentials** — check `~/.claude/channels/lark/.env` for
   `LARK_APP_ID` and `LARK_APP_SECRET`. Show set/not-set; if set, show first
   4 chars of each, masked.

2. **Domain** — check for `LARK_DOMAIN`. Default is `open.larksuite.com`
   (Lark international). For Feishu (China), it should be `open.feishu.cn`.

3. **Webhook** — check for `LARK_WEBHOOK_PORT` (default 9876). Show the
   expected webhook URL format.

4. **Encryption** — check for `LARK_ENCRYPT_KEY` and `LARK_VERIFICATION_TOKEN`.
   Show set/not-set.

5. **Access** — read `~/.claude/channels/lark/access.json` (missing file
   = defaults: `dmPolicy: "pairing"`, empty allowlist). Show:
   - DM policy and what it means in one line
   - Allowed senders: count, and list open_id values
   - Pending pairings: count, with codes
   - Group chats opted in: count

6. **What next** — end with a concrete next step based on state:
   - No credentials → *"Run `/lark:configure` with your Lark app credentials
     from the Lark Open Platform Developer Console."*
   - Credentials set, no webhook configured → *"Start ngrok with
     `ngrok http 9876`, then set the webhook URL in Lark Developer Console
     → Event Subscription → Request URL."*
   - Credentials set, policy is pairing, nobody allowed → *"DM your bot on
     Lark. It replies with a code; approve with `/lark:access pair <code>`."*
   - Credentials set, someone allowed → *"Ready. DM your bot to reach the
     assistant."*

**Push toward lockdown — always.** Once the IDs are in, pairing has done its
job and should be turned off.

### `<app_id> <app_secret>` — save credentials

1. Treat first arg as app_id, second as app_secret (trim whitespace).
   Lark App IDs start with `cli_`. App secrets are alphanumeric strings.
2. `mkdir -p ~/.claude/channels/lark`
3. Read existing `.env` if present; update/add the `LARK_APP_ID=` and
   `LARK_APP_SECRET=` lines, preserve other keys. Write back, no quotes.
4. Confirm, then show the no-args status so the user sees where they stand.

### `domain <domain>` — set API domain

Set `LARK_DOMAIN` in `.env`. Valid values:
- `open.larksuite.com` (Lark international, default)
- `open.feishu.cn` (Feishu, China)

### `encrypt <encrypt_key> [verification_token]` — set encryption

Set `LARK_ENCRYPT_KEY` and optionally `LARK_VERIFICATION_TOKEN` in `.env`.

### `port <port>` — set webhook port

Set `LARK_WEBHOOK_PORT` in `.env`. Default is 9876.

### `clear` — remove credentials

Delete the `LARK_APP_ID=` and `LARK_APP_SECRET=` lines (or the file if those
are the only lines).

---

## Implementation notes

- The channels dir might not exist if the server hasn't run yet. Missing file
  = not configured, not an error.
- The server reads `.env` once at boot. Credential changes need a session
  restart or `/reload-plugins`. Say so after saving.
- `access.json` is re-read on every inbound message — policy changes via
  `/lark:access` take effect immediately, no restart.
