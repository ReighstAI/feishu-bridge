// run-card.ts — pure rendering + transcript reduction for the live "run card".
//
// Kept separate from server.ts on purpose: server.ts has top-level startup side
// effects (it acquires the Feishu lock and opens the WebSocket the instant it's
// imported), so it can't be imported into a test without fighting the live
// bridge. Everything here is pure — (transcript entry | answer) → state →
// CardKit 2.0 card JSON — so it can be unit-tested by replaying a real
// transcript or POSTing a rendered card to the cardkit create API. server.ts
// owns the stateful orchestration (card entity lifecycle, sequence counter,
// Feishu API, tmux busy polling) and imports these functions.
//
// Design: ONE card per turn. The card mirrors the turn in Claude
// Code's NATIVE order — assistant text and tool calls interleaved as they happen,
// ending with the answer (the reply tool's `text` input, read straight from the
// transcript like any other step). No reordering, no composed summary, no second
// message. Sourcing the answer from the transcript — not a live injection racing
// the finalize timer — is what keeps a fast turn from finalizing with an empty
// card. The header is pure status (⏳ + clock while running so it never looks
// frozen; green/red/grey when it ends).
//
// CardKit 2.0 (migrated 2026-06-16): the card is a card *entity* (created via
// POST /cardkit/v1/cards, updated via PUT /cardkit/v1/cards/:id with a strictly-
// increasing sequence). 2.0 is a superset of 1.0 — colored header + interactive
// buttons (behaviors:[{type:'callback'}]) + collapsible_panel tool groups +
// streaming all on one entity. The 200-edit freeze of the old 1.0 message-PATCH
// model is gone (no per-card lifetime cap, only 10 QPS). renderRunCard returns
// the INNER card object; server.ts wraps it as {type:'card_json', data:JSON} for
// create and {card:{...}} for full-card update.

export type ToolStatus = 'running' | 'done' | 'error'
export type Terminal = 'running' | 'done' | 'error' | 'interrupted' | 'timeout'

export type Block =
  | { kind: 'text'; content: string }
  | { kind: 'tool'; id: string; desc: string; status: ToolStatus }

export interface RunCardState {
  blocks: Block[]
  sawNextTurn: boolean // a NEW inbound (<channel …>) appeared after ours → turn over
  interrupted: boolean // "[Request interrupted by user]" appeared in the tail
  // A terminal API error (content filter, overload after retries, expired auth)
  // appeared as an isApiErrorMessage entry → the turn died there, finalize red so a
  // failed turn never shows the green ✅ 完成 header. Cleared if a real answer follows
  // (recovery). A content-filter turn on 2026-06-15 finalized green; this is the fix.
  apiError: boolean
  // The reply tool delivered the answer. Any assistant TEXT after it is the model
  // narrating its own reply ("Replied. The core of what I told them: …") — drop it
  // from the card so the answer is the last thing shown, not a third-person recap.
  replied: boolean
  terminal: Terminal
  replyToolIds: Set<string> // ids of reply tool_use blocks (their text is the answer, rendered as text — their tool_result must not resolve a real tool)
  // When the turn pauses on a plan-approval dialog, the plan (pre-formatted md)
  // is held here so the SAME card grows the 批准/改一改 buttons — one card for the
  // whole turn (plan → approve → execute → answer), instead of a second plan card
  // racing the run card. Cleared on approve/cancel so the card resumes execution.
  planMd: string | null
}

export function initRunCardState(): RunCardState {
  return { blocks: [], sawNextTurn: false, interrupted: false, apiError: false, replied: false, terminal: 'running', replyToolIds: new Set(), planMd: null }
}

// Card-size belts: keep the most recent blocks and cap a single text block.
// Collapsible panels keep tool detail out of the way, but the overall card body
// is still capped at Feishu's ~30KB per-element / card limit (200099 / 11310).
const MAX_BLOCKS = 40
export const MAX_TEXT = 6000
const MAX_PLAN = 8000

export function shortText(s: unknown, n = 64): string {
  const str = String(s ?? '').replace(/\s+/g, ' ').trim()
  return str.length > n ? str.slice(0, n) + '…' : str
}

export function fmtDur(ms: number): string {
  const s = Math.floor(ms / 1000)
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  return `${m}m${s % 60}s`
}

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) + '…' : s
}

function lastPath(p: unknown): string {
  return String(p ?? '').split('/').slice(-2).join('/')
}

// A short, human line for one tool_use. Skill loads and subagents get their own
// icon because "did it load a skill / spin up a subagent" is exactly the mid-work
// visibility the run card exists to give.
export function describeTool(name: string, input: unknown): string {
  const i = (input && typeof input === 'object' ? input : {}) as Record<string, unknown>
  if (name === 'Skill') return `🧩 技能：${shortText(i.skill ?? i.name ?? i.command, 40)}`
  if (name === 'Agent' || name === 'Task') return `🤖 子任务：${shortText(i.description ?? i.subagent_type)}`
  if (name === 'Bash') return `Bash：${shortText(i.description ?? i.command)}`
  if (name === 'Read' || name === 'Edit' || name === 'Write' || name === 'NotebookEdit')
    return `${name}：${shortText(lastPath(i.file_path))}`
  if (name === 'Grep' || name === 'Glob') return `${name}：${shortText(i.pattern)}`
  if (name === 'WebSearch') return `搜索：${shortText(i.query)}`
  if (name === 'WebFetch') return `网页：${shortText(i.url)}`
  if (name === 'TodoWrite') return '更新任务清单'
  if (name.includes('feishu') || name.includes('lark')) return `飞书：${name}`
  return name
}

// Fold one parsed transcript JSONL entry into the state, in order.
export function ingestEntry(state: RunCardState, entry: any): void {
  const type = entry?.type
  const content = entry?.message?.content
  // A terminal API error (content filter, overload after retries, expired auth) is
  // logged as an assistant entry with isApiErrorMessage:true (model '<synthetic>').
  // Its "API Error: …" text still renders as a normal block below — this flag is what
  // flips the card to the red 出错 header so a blocked/failed turn never reads as 完成.
  // Verified terminal: transient 429/529 that Claude Code retries successfully never
  // stamp this field, so it's a clean signal. A real answer afterward clears it (the
  // reply branch below), so a recovered turn stays green.
  if (entry?.isApiErrorMessage === true) state.apiError = true
  if (type === 'assistant') {
    if (!Array.isArray(content)) return
    for (const block of content) {
      if (block?.type === 'tool_use' && typeof block.name === 'string') {
        // The reply tool's `text` input IS the turn's answer. Render it as a text
        // block in native order — the transcript is the single source of truth, so
        // the answer can never be lost to a finalize-vs-injection race (the bug
        // where a fast Q&A turn finalized with an empty card). Record the id so the
        // reply's tool_result doesn't get mistaken for a real tool finishing.
        if (block.name.includes('reply')) {
          const id = String(block.id ?? '')
          if (id) state.replyToolIds.add(id)
          const ans = block.input && typeof block.input === 'object' ? (block.input as Record<string, unknown>).text : ''
          if (typeof ans === 'string' && ans.trim()) {
            state.blocks.push({ kind: 'text', content: ans.trim() })
            state.apiError = false // a real answer was produced → the turn recovered, not an error
          }
          state.replied = true // the answer is delivered; later plain text is just narration
          continue
        }
        state.blocks.push({ kind: 'tool', id: String(block.id ?? ''), desc: describeTool(block.name, block.input), status: 'running' })
      } else if (block?.type === 'text' && typeof block.text === 'string' && block.text.trim()) {
        // After the reply, the model often narrates its own answer in the third person
        // ("Replied. The core of what I told them: …"). That lands as a text block here
        // and clutters the card under the answer — drop it. The reply IS the answer.
        if (state.replied) continue
        state.blocks.push({ kind: 'text', content: block.text.trim() })
      }
    }
    return
  }
  if (type === 'user') {
    if (Array.isArray(content)) {
      const results = content.filter((b: any) => b?.type === 'tool_result')
      if (results.length) {
        for (const r of results) resolveTool(state, r)
        return
      }
      const t = content.find((b: any) => b?.type === 'text')
      if (t) classifyUserText(state, String(t.text ?? ''))
      return
    }
    if (typeof content === 'string') classifyUserText(state, content)
  }
}

// The answer text to deliver as a fallback Feishu message when the finalize card PUT
// fails (so a failed card update never silently swallows the answer), OR when the
// model produced a final assistant TEXT answer but never called the `reply` tool
// (replied === false — the system prompt says it must, but that isn't enforced).
// Returns the last text block's content, or '' if there's no text answer to send.
// server.ts decides WHEN to use it (PUT-failure path; or finalize with replied===false
// and a trailing text block). Kept here so the "what is the answer" reduction stays
// with the rest of the pure transcript logic.
export function finalAnswerText(state: RunCardState): string {
  for (let i = state.blocks.length - 1; i >= 0; i--) {
    const b = state.blocks[i]
    if (b.kind === 'text') return b.content
  }
  return ''
}

// On finalize, any tool still "running" is resolved (the turn ended).
export function markToolsResolved(state: RunCardState, terminal: Terminal): void {
  for (const b of state.blocks) {
    if (b.kind === 'tool' && b.status === 'running') b.status = terminal === 'error' ? 'error' : 'done'
  }
}

function resolveTool(state: RunCardState, result: any): void {
  const id = String(result?.tool_use_id ?? '')
  if (id && state.replyToolIds.has(id)) return // reply is a text block, not a tool — don't let its result resolve a real tool
  const status: ToolStatus = result?.is_error ? 'error' : 'done'
  const byId = id
    ? state.blocks.find((b): b is Extract<Block, { kind: 'tool' }> => b.kind === 'tool' && b.id === id && b.status === 'running')
    : undefined
  const target = byId ?? state.blocks.find((b): b is Extract<Block, { kind: 'tool' }> => b.kind === 'tool' && b.status === 'running')
  if (target) target.status = status
}

// A text-bearing user entry in a bridge session is one of exactly two things
// (verified against real transcripts): a NEW inbound, which the lark channel
// always wraps as `<channel source=…>` (→ our turn is over), or the
// "[Request interrupted by user]" marker (→ the turn was interrupted). Keying on
// these specific shapes — not "any text user entry" — avoids a false turn-end if
// Claude Code ever injects other text as a user role mid-turn.
function classifyUserText(state: RunCardState, txt: string): void {
  if (txt.includes('<channel source=')) state.sawNextTurn = true
  else if (txt.includes('[Request interrupted')) state.interrupted = true
}

// A stable signature of what's visible, so the server only re-renders when
// something actually changed (the clock alone is refreshed on a slower heartbeat).
export function runCardKey(state: RunCardState): string {
  return (
    state.terminal +
    '§' +
    (state.planMd ? 'P' + state.planMd.length : '') +
    '§' +
    state.blocks.map(b => (b.kind === 'text' ? 'T' + b.content.length : b.status[0] + b.desc)).join('|')
  )
}

interface RenderOpts {
  startedAt: number
  now: number
  stopValue?: unknown // when present (running), render a ⏹ stop button carrying this value
}

// ── CardKit 2.0 element helpers ──────────────────────────────────────────────

function md(content: string): object {
  return { tag: 'markdown', content }
}

function noteMd(content: string): object {
  return { tag: 'markdown', content, text_size: 'notation' }
}

// Collapsible panel header: a markdown title + the chevron that rotates on expand.
function panelHeader(titleMd: string): object {
  return {
    title: { tag: 'markdown', content: titleMd },
    vertical_align: 'center',
    icon: { tag: 'standard_icon', token: 'down-small-ccm_outlined', size: '16px 16px' },
    icon_position: 'follow_text',
    icon_expanded_angle: -180,
  }
}

// A group of consecutive tool calls as one collapsible panel. Expanded while the
// turn runs (live visibility), collapsed once it ends (clean recap). Bodies are
// one-line summaries (describeTool), so size stays well under the element cap.
function toolPanel(lines: string[], expanded: boolean, anyError: boolean): object {
  const title = `🔧 **${lines.length} 步**`
  return {
    tag: 'collapsible_panel',
    expanded,
    header: panelHeader(title),
    border: { color: anyError ? 'red' : 'grey', corner_radius: '5px' },
    vertical_spacing: '4px',
    padding: '6px 8px 6px 8px',
    elements: [{ tag: 'markdown', content: lines.join('\n'), text_size: 'notation' }],
  }
}

function button(content: string, type: string, value: unknown): object {
  return { tag: 'button', text: { tag: 'plain_text', content }, type, behaviors: [{ type: 'callback', value }] }
}

function headerFor(state: RunCardState, elapsed: number): { template: string; title: string } {
  const dur = fmtDur(elapsed)
  switch (state.terminal) {
    case 'done': return { template: 'green', title: `✅ 完成 · ${dur}` }
    case 'error': return { template: 'red', title: `⚠️ 出错 · ${dur}` }
    case 'interrupted': return { template: 'grey', title: `⏹ 已中断 · ${dur}` }
    case 'timeout': return { template: 'orange', title: `⏱ 超时（无响应）· ${dur}` }
    default: return { template: 'blue', title: `⏳ 工作中 · ${dur}` }
  }
}

function summaryText(state: RunCardState): string {
  if (state.planMd && state.terminal === 'running') return '方案待审核'
  switch (state.terminal) {
    case 'done': return '已完成'
    case 'error': return '出错'
    case 'interrupted': return '已中断'
    case 'timeout': return '超时'
    default: return '工作中'
  }
}

// Render the INNER 2.0 card object. server.ts wraps it for create / full-update.
// streaming_mode is on only while running (so the live text element — added in a
// later increment — animates); off for the plan-approval view and once finalized
// so the buttons' callbacks settle normally.
export function renderRunCard(state: RunCardState, opts: RenderOpts): object {
  // Plan-approval view: the turn paused on a plan dialog. The SAME card shows the
  // plan + 批准/取消 buttons (orange header). Cleared (planMd → null) on
  // approve/cancel, after which the card falls through to the normal render below.
  if (state.planMd && state.terminal === 'running') {
    return {
      schema: '2.0',
      config: { streaming_mode: false, summary: { content: '方案待审核' } },
      header: { template: 'orange', title: { tag: 'plain_text', content: `📋 方案待审核 · ${fmtDur(opts.now - opts.startedAt)}` } },
      body: {
        elements: [
          md(truncate(state.planMd, MAX_PLAN) || '(无方案内容)'),
          { tag: 'hr' },
          button('✅ 批准执行', 'primary', { t: 'plan', a: 'approve' }),
          button('✋ 取消', 'default', { t: 'plan', a: 'revise' }),
          noteMd('✏️ 想改方案？直接回复一条消息说要改什么，Claude 会按你的意见重新规划。'),
        ],
      },
    }
  }

  const { template, title } = headerFor(state, opts.now - opts.startedAt)
  const running = state.terminal === 'running'

  let blocks = state.blocks
  let dropped = 0
  if (blocks.length > MAX_BLOCKS) { dropped = blocks.length - MAX_BLOCKS; blocks = blocks.slice(-MAX_BLOCKS) }

  const elements: object[] = []
  if (dropped) elements.push(noteMd(`…（更早的 ${dropped} 步已省略）`))

  // Native order: walk blocks; group consecutive tool calls into one collapsible
  // panel, render each text block as markdown. The last tool group stays expanded
  // while running so live progress is visible without tapping.
  let i = 0
  const rendered: { el: object; isLastTools: boolean }[] = []
  const toolGroupIdx: number[] = []
  while (i < blocks.length) {
    const b = blocks[i]
    if (b.kind === 'tool') {
      const lines: string[] = []
      let anyError = false
      while (i < blocks.length) {
        const t = blocks[i]
        if (t.kind !== 'tool') break
        const icon = t.status === 'done' ? '✓' : t.status === 'error' ? '✗' : '▸'
        if (t.status === 'error') anyError = true
        lines.push(`${icon} ${t.desc}`)
        i++
      }
      toolGroupIdx.push(rendered.length)
      rendered.push({ el: toolPanel(lines, false, anyError), isLastTools: false })
      // stash the raw inputs so we can re-render the last group expanded below
      ;(rendered[rendered.length - 1] as any)._lines = lines
      ;(rendered[rendered.length - 1] as any)._err = anyError
    } else {
      rendered.push({ el: md(truncate(b.content, MAX_TEXT)), isLastTools: false })
      i++
    }
  }
  // Expand the last tool group while running, so the latest activity is visible.
  if (running && toolGroupIdx.length) {
    const last = toolGroupIdx[toolGroupIdx.length - 1]
    const r = rendered[last] as any
    r.el = toolPanel(r._lines, true, r._err)
  }
  for (const r of rendered) elements.push(r.el)

  if (!elements.length) {
    // A card with no content blocks: while running it's just "warming up"; once it
    // ends, say so plainly so the re-render is unmistakable.
    const empty =
      state.terminal === 'interrupted' ? '_本轮已终止_'
      : state.terminal === 'timeout' ? '_本轮超时，无响应_'
      : state.terminal === 'error' ? '_本轮出错_'
      : state.terminal === 'done' ? '_本轮无输出_'
      // Running with nothing in the transcript yet — most visible on a cold session's
      // first turn, where Claude can take minutes to load the brain before the first
      // token. A bare "…" reads as stuck; say it's thinking so the moving clock + this
      // line together signal "alive, working" rather than "frozen".
      : '🧠 正在思考…'
    elements.push(md(empty))
  }

  if (running && opts.stopValue !== undefined) {
    elements.push(button('⏹ 终止', 'danger', opts.stopValue))
  }

  return {
    schema: '2.0',
    // streaming_mode stays FALSE this increment. We don't yet stream a text element
    // (the typewriter is a later increment), so it buys nothing now — and a card in
    // streaming_mode can suppress button callbacks, which would kill the ⏹ stop
    // button mid-turn. The clock animates via the server's ~2s repaint heartbeat,
    // not streaming_mode. Flip to true (and add the streaming element + element_id +
    // a settings streaming_mode:false on finalize) when the typewriter ships.
    config: { streaming_mode: false, summary: { content: summaryText(state) } },
    header: { template, title: { tag: 'plain_text', content: title } },
    body: { elements },
  }
}
