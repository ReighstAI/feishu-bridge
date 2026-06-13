---
name: takeover
description: Take over the Lark WebSocket connection from another Claude Code session. Use when Lark messages are going to a different session, or when you want to switch Lark to the current session.
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Bash(ls *)
  - Bash(mkdir *)
---

# /lark:takeover — Take Over Lark Connection

Takes the Lark WebSocket connection from another session and assigns it to
this one. The other session will detect the takeover and disconnect within
a few seconds.

Arguments passed: `$ARGUMENTS`

---

## Dispatch on arguments

### No args — take over

1. Read the session registry at `~/.claude/channels/lark/sessions/`.
   Each file is `{pid}.json` containing `{ pid, ppid, cwd, startedAt }`.
   List all files and read them. Skip files where the process is dead.

2. Read `~/.claude/channels/lark/ws.lock` to show the current lock owner.

3. Find **this session's** entry. The entry whose `cwd` matches the
   current working directory is most likely this session. If ambiguous
   (multiple sessions with same cwd), show the list and ask the user
   to pick by PID.

4. Write the takeover signal file:
   ```bash
   mkdir -p ~/.claude/channels/lark
   ```
   Write `~/.claude/channels/lark/takeover` with this session's `ppid`
   value from the registry (the `bun run` wrapper PID).

   The server.ts poll loop checks if this matches `process.ppid` and
   takes over the lock if it does.

5. Confirm: "Takeover requested. The Lark connection will switch to this
   session within a few seconds."

### `status` — show current state

1. Read `~/.claude/channels/lark/ws.lock`.
2. Show: owner PID, started time, whether the process is alive.
3. Read all files in `~/.claude/channels/lark/sessions/` and display
   each session's PID, cwd, and startedAt. Mark which one holds the lock.

---

## Implementation notes

- Each `server.ts` registers itself at startup by writing
  `~/.claude/channels/lark/sessions/{pid}.json`.
- Dead sessions are automatically cleaned up when listed.
- The takeover signal file is ephemeral — the target server.ts deletes it
  after reading.
- The previous lock holder detects the signal, releases its lock, and
  closes its WSClient.
- The target server.ts acquires the lock and starts its WSClient.
- The whole process takes ~3 seconds (one poll interval).
