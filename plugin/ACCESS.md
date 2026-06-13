# Lark — Access & Delivery

Lark controls who can message your bot based on your app's visibility settings in the Lark Developer Console. Custom apps (self-built) are only available within your organization. Store apps can be published publicly.

For DMs that do get through, the default policy is **pairing**. An unknown sender gets a 6-character code in reply and their message is dropped. You run `/lark:access pair <code>` from your assistant session to approve them. Once approved, their messages pass through.

All state lives in `~/.claude/channels/lark/access.json`. The `/lark:access` skill commands edit this file; the server re-reads it on every inbound message, so changes take effect without a restart. Set `LARK_ACCESS_MODE=static` to pin config to what was on disk at boot (pairing is unavailable in static mode since it requires runtime writes).

## At a glance

| | |
| --- | --- |
| Default policy | `pairing` |
| Sender ID | open_id (e.g. `ou_xxxxxxxxxxxxxxxx`) |
| Group key | chat_id (e.g. `oc_xxxxxxxxxxxxxxxx`) |
| Config file | `~/.claude/channels/lark/access.json` |

## DM policies

`dmPolicy` controls how DMs from senders not on the allowlist are handled.

| Policy | Behavior |
| --- | --- |
| `pairing` (default) | Reply with a pairing code, drop the message. Approve with `/lark:access pair <code>`. |
| `allowlist` | Drop silently. No reply. Use this once everyone who needs access is already on the list. |
| `disabled` | Drop everything, including allowlisted users and group chats. |

```
/lark:access policy allowlist
```

## User IDs

Lark identifies users by **open_id**: app-scoped user IDs like `ou_xxxxxxxxxxxxxxxx`. These are stable within your app but differ across apps. The allowlist stores open_id values.

Pairing captures the ID automatically. To add someone manually, you need their open_id — this can be found via the Lark Admin Console or the Lark API (`/contact/v3/users`).

```
/lark:access allow ou_xxxxxxxxxxxxxxxx
/lark:access remove ou_xxxxxxxxxxxxxxxx
```

## Group chats

Group chats are off by default. Opt each one in individually, keyed on the **chat_id** (starts with `oc_`). Find chat IDs from the Lark API or by checking the webhook event payload.

```
/lark:access group add oc_xxxxxxxxxxxxxxxx
```

With the default `requireMention: true`, the bot responds only when @mentioned. Pass `--no-mention` to process every message in the group, or `--allow id1,id2` to restrict which members can trigger it.

```
/lark:access group add oc_xxxxxxxxxxxxxxxx --no-mention
/lark:access group add oc_xxxxxxxxxxxxxxxx --allow ou_xxx,ou_yyy
/lark:access group rm oc_xxxxxxxxxxxxxxxx
```

## Mention detection

In group chats with `requireMention: true`, the bot is triggered when:

- A structured @bot mention in the message (detected via message.mentions)
- A match against any regex in `mentionPatterns`

Example regex setup:

```
/lark:access set mentionPatterns '["@claude", "\\bassistant\\b"]'
```

## Delivery

Configure outbound behavior with `/lark:access set <key> <value>`.

**`ackReaction`** reacts to inbound messages on receipt as a "seen" acknowledgment. Use Lark emoji type names (THUMBSUP, HEART, SMILE, etc). Empty string disables.

```
/lark:access set ackReaction THUMBSUP
/lark:access set ackReaction ""
```

**`replyToMode`** controls threading on chunked replies. When a long response is split, `first` (default) threads only the first chunk under the inbound message; `all` threads every chunk; `off` sends all chunks standalone.

**`textChunkLimit`** sets the split threshold. Default is 4000 characters.

**`chunkMode`** chooses the split strategy: `length` cuts exactly at the limit; `newline` prefers paragraph boundaries.

## Skill reference

| Command | Effect |
| --- | --- |
| `/lark:access` | Print current state: policy, allowlist, pending pairings, enabled groups. |
| `/lark:access pair a4f91c` | Approve pairing code `a4f91c`. Adds the sender to `allowFrom` and sends a confirmation on Lark. |
| `/lark:access deny a4f91c` | Discard a pending code. The sender is not notified. |
| `/lark:access allow ou_xxxx` | Add an open_id directly. |
| `/lark:access remove ou_xxxx` | Remove from the allowlist. |
| `/lark:access policy allowlist` | Set `dmPolicy`. Values: `pairing`, `allowlist`, `disabled`. |
| `/lark:access group add oc_xxxx` | Enable a group chat. Flags: `--no-mention`, `--allow id1,id2`. |
| `/lark:access group rm oc_xxxx` | Disable a group chat. |
| `/lark:access set ackReaction THUMBSUP` | Set a config key. |

## Config file

`~/.claude/channels/lark/access.json`. Absent file is equivalent to `pairing` policy with empty lists.

```jsonc
{
  // Handling for DMs from senders not in allowFrom.
  "dmPolicy": "pairing",

  // User open_ids allowed to DM.
  "allowFrom": ["ou_xxxxxxxxxxxxxxxx"],

  // Group chats the bot is active in. Empty object = DM-only.
  "groups": {
    "oc_xxxxxxxxxxxxxxxx": {
      // true: respond only to @mentions.
      "requireMention": true,
      // Restrict triggers to these senders. Empty = any member (subject to requireMention).
      "allowFrom": []
    }
  },

  // Case-insensitive regexes that count as a mention.
  "mentionPatterns": ["@claude"],

  // Reaction on receipt. Lark emoji type name. Empty string disables.
  "ackReaction": "THUMBSUP",

  // Threading on chunked replies: first | all | off
  "replyToMode": "first",

  // Split threshold. Default 4000.
  "textChunkLimit": 4000,

  // length = cut at limit. newline = prefer paragraph boundaries.
  "chunkMode": "newline"
}
```
