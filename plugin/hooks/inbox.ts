import type { EngineInterface, Register } from 'claude-code'

// Delivers outside comments (Remarc today) to this session as prompts. The companion decides
// which sessions get an inbox: only main sessions, never worktree ones. Protocol:
//   GET  /inbox/:session          -> {armed: false} | {armed: true, prompt?, ids?, error?}
//   POST /inbox/:session/release  {ids} -> hands comments back that could not be submitted
const COMPANION = 'http://127.0.0.1:5173'
const POLL_MS = 10_000

export const register: Register = on => {
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

  on('session.start', async ($, e, next) => {
    $.clock.every(POLL_MS, () => void poll($))
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
