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
const inboxHeaders = { 'x-companion-inbox': 'phone-whip' }

type AskReply =
  | { status: 'pending' }
  | { status: 'answered'; answers: Record<string, string>; annotations?: Record<string, unknown> }
  | { status: 'declined' }
  | { status: 'cancelled' }
  | { status: 'interrupted' }

let isTurnRunning = false
let runningTurn: string | undefined
let isPolling = false
// What the agent said when its last turn ended: the phone shows it on a long press.
let lastMessage = ''

async function poll($: EngineInterface) {
  if (isPolling) return
  isPolling = true
  try {
    const [sessionId, cwd] = await Promise.all([$.session.id(), $.session.cwd()])
    const inbox = `${COMPANION}/inbox/${encodeURIComponent(sessionId)}`
    const res = await $.http.fetch(`${inbox}/check-in`, {
      method: 'POST',
      headers: { ...inboxHeaders, 'content-type': 'application/json' },
      body: JSON.stringify({ cwd, idle: !isTurnRunning, last: lastMessage.slice(-8000) }),
    })
    if (!res.ok) return
    const reply = JSON.parse(res.text) as { armed: boolean; prompt?: string; ids?: string[]; dictation?: string; interrupt?: boolean }
    if (!reply.armed || !reply.prompt) return
    // A steering message from the phone lands mid-turn: stop the running turn, then say it.
    if (reply.interrupt && isTurnRunning && runningTurn) {
      await $.turn.abort({ turnId: runningTurn }).catch(() => {})
    }
    const submitted = await $.prompt.submit({ text: reply.prompt })
    const dropped = submitted.drop !== undefined
    if (reply.dictation || dropped) {
      await $.http.fetch(`${inbox}/release`, {
        method: 'POST',
        headers: { ...inboxHeaders, 'content-type': 'application/json' },
        body: JSON.stringify(reply.dictation
          ? { dictation: reply.dictation, retry: dropped }
          : { ids: reply.ids ?? [] }),
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

  // Polls for Remarc comments and Phone Whip dictation addressed to this session.
  // (One module per plugin, so this lives beside the ask mod.)
  on('session.start', async ($, e, next) => {
    $.clock.after(1500, () => void poll($))
    $.clock.every(3_000, () => void poll($))
    return next(e)
  })
  on('turn.start', ($, e, next) => {
    if (e.agentId === undefined) { isTurnRunning = true; runningTurn = e.turnId }
    return next(e)
  })
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined) {
      if (result?.text) lastMessage = result.text
      isTurnRunning = false
      runningTurn = undefined
      $.clock.after(1500, () => void poll($))
    }
    return result
  })
}
