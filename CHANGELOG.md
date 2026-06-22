# Changelog

All notable changes to the Feishu ↔ Claude Code bridge. Versions follow
semantic versioning. The running bridge stamps its version in the connection
log: `connected (bot: …) [vX.Y.Z]`.

## 0.14.0 — 2026-06-21

- **Reverted: long-lived auth token.** An earlier same-day 0.14.0 added optional
  `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) support to dodge the
  keychain-OAuth `Please run /login · 401` lockouts. It was **reverted the same
  day**: interactive Claude Code — which is what the bridge runs — does **not**
  honor `CLAUDE_CODE_OAUTH_TOKEN`; only `claude -p` / headless does. With the env
  var set, the interactive session even shows "Claude API" in its banner but still
  401s. So the token never actually authenticated the bridge. The bridge stays on
  keychain login; recover a 401 by running `/login` in the bridge session. The
  mitigation that does help: make sure only ONE `claude --channels` process runs
  (`pgrep -f 'channels plugin:lark'`) — multiple processes invalidate each other's
  login and accelerate expiry.

## 0.13.0 — 2026-06-17

Batch B: three turn-delivery and connection-resilience fixes.

- **Rapid-input debounce-merge.** When you send text and then several files in
  quick succession, the text used to start a turn before the files arrived (an
  idle-start race), spilling the attachments into a second turn. A short per-chat
  debounce (600ms) on the outbound forward now coalesces a burst into one turn,
  promoting each attachment to a channel attribute and inlining every path with an
  explicit Read instruction so none is missed. A single message in the window is
  forwarded byte-identically (no behavior change). Relaunch commands (`/new`,
  `/mode`) and `/stop` drop the buffer rather than flush it, so a superseded
  message never runs.
- **Sleep/wake forced reconnect.** A watcher tied to socket ownership detects the
  event-loop freeze of a machine sleep/suspend (a gap far larger than its tick) and
  forces a WebSocket reconnect immediately, instead of waiting for the SDK's next
  ping + 10s timeout to notice the dead socket. This closes the post-wake blind
  window where messages silently went nowhere.
- **Long-answer full delivery.** The run card is a status surface, not a long-text
  channel — it truncates the answer to a preview past a size cap. When an answer
  exceeds that cap, the full text is now also sent as a normal chunked message
  (plain text so code blocks survive literally), so nothing is lost. Short answers
  (the common case) keep the unchanged card-only path.

## 0.12.1 — 2026-06-17

- **Installer sets up voice transcription (best-effort).** The bridge has long
  supported transcribing voice messages (0.12.0), but the installer never set up
  the transcriber — so out of the box, voice degraded to a raw audio path. The
  installer now installs `whisper-cpp` + `ffmpeg` via Homebrew, downloads the
  `ggml-base.bin` model (~142MB) to `~/.local/share/whisper-cpp/`, and drops a
  `whisper-transcribe` wrapper at `~/.local/bin/`. Entirely best-effort: no
  Homebrew, no network, or a failed download all just `warn` and continue — the
  core bridge install never fails over voice. Idempotent: re-running won't
  re-download an existing model. Voice then transcribes automatically; if a
  component is missing it falls back to the audio path as before.

## 0.12.0 — 2026-06-16

Parity bump: the live turn surface is rebuilt and the reliability/UX hardening
from the 0.10–0.12 line lands.

- **Run-card UI.** One persistent card per turn, mirroring the terminal in native
  order: assistant text and tool calls interleaved as they happen, grouped into
  collapsible panels, ending with the answer. A running clock keeps it from ever
  looking frozen; the header settles green / red / grey / orange when the turn
  ends (done / error / interrupted / timeout). The answer is sourced from the
  transcript, so a fast Q&A can't finalize with an empty card.
- **`/mode`, `/clear`, `/context`, `/help`.** `/mode` switches permission mode but
  keeps the conversation (resumes the same session); `/clear` confirms plainly that
  context was wiped; `/context` trims the usage chart to a glanceable summary;
  `/help` replies with what actually works from a phone. Unknown commands get an
  honest "not available here" instead of a misleading "sent".
- **`/effort` intercept.** It's a launch flag, not a TUI command — the bridge now
  says so plainly instead of silently no-op'ing.
- **Network retry + backoff.** API calls retry on transient failures (HTTP 429/5xx,
  rate-limit and network errors) with fixed backoff; harmless stale-sequence card
  errors are classified and ignored so they don't abandon a healthy card.
- **Voice transcription.** Voice messages are transcribed by the bridge so the
  model receives text, not an audio path. Configurable binary
  (`LARK_WHISPER_BIN`); degrades gracefully to the audio path if no transcriber is
  installed.
- **Crash-resume.** An unexpected exit (OOM / context overflow) resumes the
  conversation on relaunch instead of starting fresh.
- **Answer-delivery fallback.** If the final card update fails, or the model
  produced an answer but never called the reply tool, the answer is still
  delivered as a normal message rather than stranded in a frozen card.
- **Card resilience.** Repeated update failures stop the high-frequency repaint
  but keep the card alive so the terminal state still lands; the dead-socket
  watchdog (ping timeout) is re-enabled to close the post-wake blind window.

## 0.9.2 — 2026-06-14

Fix: re-running the installer to upgrade silently reset the permission mode (and
workdir) to the built-in default, because it ignored the saved `bridge.conf`. The
documented upgrade — `git pull && ./install.sh --auto` with nothing passed —
would flip a bypassPermissions bridge back to acceptEdits. The installer now
reads the existing `bridge.conf` and reuses those values as the defaults. An
explicit env var still overrides; a fresh install still falls back to
`$HOME` / `acceptEdits`.

## 0.9.1 — 2026-06-14

Fix: a fresh-machine install could deadlock at boot on two interactive dialogs
that fire *before* the channel connects — so nothing surfaces to Feishu and the
bridge silently never answers (and re-hangs on every reboot). A machine that has
already accepted both dialogs by hand never sees this, which is why it slipped
through pre-release testing.

- **Workspace-trust dialog** ("Do you trust the files in this folder?"): fires in
  every permission mode, including bypass; there is no CLI flag to skip it for an
  interactive session (only `-p`/non-interactive skips it). The installer now
  marks the chosen workdir trusted in `~/.claude.json` (atomic temp+rename,
  merge-safe) — equivalent to clicking "Yes, I trust this folder".
- **Bypass-mode warning**: the one-time "Bypass Permissions" prompt. The
  generated `bridge-settings.json` now carries `skipDangerousModePermissionPrompt:
  true`, loaded at boot via `--settings` (same path that already pre-clears the
  project-MCP discovery prompt).

Upgrade: `cd ~/feishu-bridge && git pull && ./install.sh --auto` (reuses creds),
then `launchctl kickstart -k gui/$(id -u)/com.feishu-bridge.daemon` to restart
once and confirm the headless relaunch reconnects.

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
