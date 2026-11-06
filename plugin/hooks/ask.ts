import type { EngineInterface, Register } from 'claude-code'

// The companion server. Protocol:
//   POST /ask            {session_id, cwd, tool_use_id, questions} -> {id}
//   GET  /ask/:id?wait=N -> {status:'pending'} | {status:'answered', answers, annotations?}
//                           | {status:'declined'}  (stamped in the companion)
//                           | {status:'cancelled'} (companion closed: ask in the terminal instead)
//   POST /ask/:id/cancel -> tells the companion the question is gone (interrupt)
const COMPANION = 'http://127.0.0.1:5173'
// Kept under the engine's 5s linger after an interrupt, so the loop always sees the abort in time.
const POLL_WAIT_S = 4

type AskReply =
  | { status: 'pending' }
  | { status: 'answered'; answers: Record<string, string>; annotations?: Record<string, unknown> }
  | { status: 'declined' }
  | { status: 'cancelled' }
  | { status: 'interrupted' }

let isTurnRunning = false
let isPolling = false
let sessionId: string | undefined

async function poll($: EngineInterface) {
  if (isPolling || isTurnRunning) return
  isPolling = true
  try {
    sessionId ??= await $.session.id()
    const res = await $.http.fetch(`${COMPANION}/inbox/${encodeURIComponent(sessionId)}`)
    const reply = JSON.parse(res.text) as { armed: boolean; prompt?: string; ids?: string[] }
    if (!reply.armed || !reply.prompt) return
    const submitted = await $.prompt.submit({ text: reply.prompt })
    if (submitted.drop !== undefined) {
      await $.http.fetch(`${COMPANION}/inbox/${encodeURIComponent(sessionId)}/release`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ ids: reply.ids ?? [] }),
      })
    }
  } catch {
    // The companion is not running: nothing to deliver.
  } finally {
    isPolling = false
  }
}

export const register: Register = on => {
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    const [session_id, cwd] = await Promise.all([$.session.id(), $.session.cwd()])

    // Hand the question to the companion. Unreachable or refused: Claude's own dialog.
    let id: string
    try {
      const res = await $.http.fetch(`${COMPANION}/ask`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ session_id, cwd, tool_use_id: e.tool_use_id, questions: e.questions }),
      })
      if (!res.ok) return next(e)
      id = JSON.parse(res.text).id
    } catch {
      return next(e)
    }

    $.ui.status('Question sent to the companion')
    // Interrupt (Esc): tell the companion at once so the character leaves, even mid-poll.
    const cancel = () => { $.http.fetch(`${COMPANION}/ask/${id}/cancel`, { method: 'POST' }).catch(() => {}) }
    next.signal.addEventListener('abort', cancel, { once: true })
    try {
      while (!next.signal.aborted) {
        let reply: AskReply
        try {
          const res = await $.http.fetch(`${COMPANION}/ask/${id}?wait=${POLL_WAIT_S}`)
          reply = JSON.parse(res.text)
        } catch {
          // Companion went away mid-question: ask in the terminal instead.
          return next(e)
        }
        if (reply.status === 'answered')
          return {
            result: {
              questions: e.questions,
              answers: reply.answers,
              ...(reply.annotations ? { annotations: reply.annotations } : {}),
            },
          }
        if (reply.status === 'declined') return { deny: 'The user declined to answer.' }
        if (reply.status === 'cancelled') return next(e)
        if (reply.status === 'interrupted') break
      }
      return { deny: 'The user interrupted the question.' }
    } finally {
      next.signal.removeEventListener('abort', cancel)
      $.ui.status(undefined)
    }
  })

  // Delivers outside comments (Remarc today) to this session as prompts. The companion decides
  // which sessions get an inbox: only main sessions, never worktree ones. Protocol:
  //   GET  /inbox/:session          -> {armed: false} | {armed: true, prompt?, ids?, error?}
  //   POST /inbox/:session/release  {ids} -> hands comments back that could not be submitted
  // (One module per plugin, so this lives beside the ask mod.)
  on('session.start', async ($, e, next) => {
    $.clock.every(10_000, () => void poll($))
    return next(e)
  })
  on('turn.start', ($, e, next) => {
    if (e.agentId === undefined) isTurnRunning = true
    return next(e)
  })
  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      isTurnRunning = false
      $.clock.after(1500, () => void poll($))
    }
    return next(e)
  })
}
