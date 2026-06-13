# Changelog

All notable changes to the Feishu ↔ Claude Code bridge. Versions follow
semantic versioning. The running bridge stamps its version in the connection
log: `connected (bot: …) [vX.Y.Z]`.

## 0.9.0 — 2026-06-13

Consolidates the development versions 0.3–0.9 (built and verified on a live
bridge before release). Headline: the bridge is now a full mirror of the
terminal — anything Claude Code shows or asks reaches Feishu, answerable by
tapping a button or typing a reply.

- **Everything Claude Code asks now surfaces to Feishu**, answerable by button
  or free text: tool-permission prompts, plan approve/revise, AskUserQuestion
  (pick a choice *or* type your own answer), and any other numbered picker
  (MCP-trust, `/model`, …). Nothing the TUI asks can hang invisibly anymore.
- **Slash-command output mirrors to Feishu.** Forwarded commands used to run
  silently; now `/context`, `/status`, `/help`, `/fast` etc. send their output
  back. Modal screens are read and then auto-dismissed so they don't swallow the
  next message; pickers become tappable cards.
- **"Still working" clock on every turn.** The progress card carries a running
  timer that keeps advancing even during a single long step, so a slow turn
  never looks frozen. The post-approval run shows the same clock.
- **Plan-revise from the phone, in any language.** Reply with what to change and
  the plan is regenerated. Text is delivered via the paste buffer (tmux
  `send-keys` silently drops non-ASCII, which had been eating Chinese replies).
  The revise field is found by its label, not a fixed option number, and the
  flow backs out safely rather than risk a wrong approval if it can't find it.
- **Card updates fixed (the big one).** Interactive cards are updated via
  `PATCH {content}`; the old `PUT` + `msg_type` returned `230001` and silently
  failed, so approve/progress/confirmation cards never updated. This is why
  "approve did nothing" — the button worked; the feedback never arrived.
- **Bridge-own Feishu tools pre-allowed** in `bridge-settings.json` so a
  non-bypass session never freezes trying to reply.
- Live-progress card no longer breaks on the 80-col line-wrap; long dialog
  phrases are matched after flattening whitespace.

## 0.2.0 — 2026-06-13

- **Plan-mode approval works from Feishu.** The approval card is now presented
  by detecting the TUI plan dialog directly (pane-based), so it appears whether
  or not the model reached approval via the `ExitPlanMode` tool. Previously the
  card silently failed when the brain-loaded session wrote a plan file instead
  of calling `ExitPlanMode`.
- **`/new` no longer hangs behind a modal dialog.** It now dismisses any open
  plan-approval / tool-permission dialog (Escape + clear input) before quitting,
  so the relaunch always lands.
- **Non-bypass launches no longer hang at the project-MCP discovery prompt**
  (bridge-scoped `enableAllProjectMcpServers`, applied via `--settings`).
- Card button clicks are now traced in `server.log` for diagnosability.

## 0.1.0 — 2026-06-13

- **`/new` interactive permission-mode card** — pick default / acceptEdits /
  plan / bypass with a button; the session relaunches in that mode.
- **`/stop`** interrupts the running turn; **`/compact`** reports when
  compaction actually finishes (not just when sent).
- **Trust-first-sender pairing** — the first DM auto-authorizes and locks; no
  pairing code needed (used for first-run setup).
- **Voice-message transcription** and file send/receive.
- **Live progress card** — a placeholder card tails the session transcript and
  shows tool calls + narration as the turn runs.
- All other `/slash` commands forwarded into the real TUI (`/model`, `/effort`,
  `/status`, `/resume`, …); `/login` and `/logout` excluded.
