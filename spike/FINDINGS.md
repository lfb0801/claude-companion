# Phase 0 spike: findings

Run on 2026-11-06 against Claude Code 2.1.319 (Haiku), manual permission mode, HTTP hooks posting to
`spike/hook-spike.mjs`. Sessions were driven through tmux and observed with `tmux capture-pane`.
Sanitized recordings are in `tests/fixtures/spike/`.

## Answers to the plan questions

| Question | Result |
|---|---|
| Does the terminal dialog show while a PermissionRequest hook is held? | **Yes.** It shows within a second, and a `Notification` (`permission_prompt`) fires about 6s later. |
| Can you answer in the terminal while the hook is held? | **Yes.** The tool runs (allow) or the turn is interrupted (deny). |
| Does a companion answer dismiss the terminal dialog? | **Yes.** The dialog closes and the transcript shows "Allowed/Denied by PermissionRequest hook". |
| What happens when `timeout` expires? | Claude closes the HTTP connection at exactly `timeout` seconds. The terminal dialog stays up and still works. Nothing is lost. |
| How high can `timeout` go? | **Above 600s.** With `timeout: 86400` a hold of 700s was honoured: the allow came back at 700,011 ms and the command ran. The upper limit was not probed further. |
| Does PreToolUse + `updatedInput.answers` answer AskUserQuestion? | **Yes**, but while PreToolUse is held the terminal shows **nothing**. |
| Better: does a held **PermissionRequest** answer AskUserQuestion? | **Yes.** AskUserQuestion and ExitPlanMode both raise a PermissionRequest. The question/plan is visible in the terminal while it is held, and `decision: {behavior: "allow", updatedInput: {...tool_input, answers: {"<question>": "<label>"}}}` answers it. |

## Behaviour the server must handle

- **Terminal allow does not close the hook connection.** Claude leaves the held request open until the hook's
  own timeout. The server has to notice the answer itself: a `PostToolUse` for the same tool call, or the
  `tool_result` in the transcript.
- **Terminal deny closes the hook connection** (the turn is interrupted). No `PostToolUse` and no `Stop` fire.
  The transcript gets a `tool_result` with `is_error: true`, `toolUseResult: "User rejected tool use"`, then a
  user text `[Request interrupted by user for tool use]`.
- **PermissionRequest has no `tool_use_id`.** It arrives about 15ms after the `PreToolUse` for the same call
  (which does have `tool_use_id`). Pair them by session + `tool_name` + `tool_input`.
- **AskUserQuestion via PreToolUse `allow` skips the PermissionRequest entirely.** Use PermissionRequest only,
  so all three prompt kinds (tool permission, question, plan) go through one path and stay answerable in both
  places.
- **ExitPlanMode deny** keeps the session in plan mode, and the deny `message` reaches Claude as feedback.
- **`session_title` is not in any hook payload.** The transcript has `{"type":"ai-title","aiTitle":"..."}`
  entries (repeated, latest wins).
- `Notification` with `notification_type: "idle_prompt"` fired about 60s after `Stop`.
- Hook requests come from `axios` with `content-type: application/json`. There is no auth header.
- Payloads include `prompt_id`, `permission_mode`, `effort`; `PermissionRequest` for Bash includes
  `permission_suggestions` (the "always allow" options).
- Question option descriptions can carry text added by other plugins (here: `· ~$0.00–0.00` cost markers
  from a local estimate plugin). The picker UI shows them as-is.

## Decision: how the hook waits

**Tool permissions and ExitPlanMode** go through a held `PermissionRequest` HTTP hook with a very high `timeout`
(86400). It is answerable in the companion *and* the terminal, whichever comes first:

- No companion tab connected: reply `{}` at once, and the terminal dialog handles it as usual.
- Answered in the companion: reply with the decision. The terminal dialog closes by itself.
- Answered in the terminal: detect it (allow: `PostToolUse` / `tool_result`; deny: the hook connection closes plus
  the "User rejected tool use" `tool_result`), then clear the character. Close the held request with `{}` on
  allow, since Claude never closes it.

**Questions (AskUserQuestion)** are answered by a Claude Code **mod** (`companion-ask`), not by a hook. A
`tool.call` hook on `AskUserQuestion` sends the question to the companion and returns the answer as the tool's
own result, so Claude reads an ordinary AskUserQuestion result ("User answered Claude's questions: … → Blue").
The terminal dialog is never drawn while the companion is up.

Protocol (served by the companion server; the spike server implements it):

| Call | Meaning |
|---|---|
| `POST /ask {session_id, cwd, tool_use_id, questions}` → `{id}` | A new question. A non-2xx status or no server: the mod falls back to Claude's own dialog. |
| `GET /ask/:id?wait=4` → `{status: pending}` / `{status: answered, answers, annotations?}` / `{status: cancelled}` | Long-poll. `cancelled` from the companion also falls back to the terminal dialog. |
| `POST /ask/:id/cancel` | Sent by the mod when the user presses Esc in the session. |

Tested end to end (session-c, session-d and `companion-ask.asks.jsonl` fixtures):

- Answer from the companion: Claude gets the answer. The status line shows "Question sent to the companion"
  while waiting.
- Esc in the terminal while waiting: Claude records "User declined to answer questions", and the companion gets
  the cancel at once.
- Companion down: Claude's own dialog appears and works.

Things to know about the mod:

- **Settings hooks do not see these questions.** No `PreToolUse`/`PostToolUse`/`PermissionRequest` fires for an
  AskUserQuestion the mod answers. The companion learns about questions only through `/ask`.
- **Polls must stay under 5s.** After an interrupt the engine gives a hook 5s (`lingerMs`) to finish. A first
  version with 20s polls never sent its cancel. The mod now sends the cancel from an abort listener and polls
  every 4s.
- `$.http.fetch` has no abort signal, hence the long-poll slices.
- A copy of the mod is in `plugin/companion-ask/`. It merges into the companion plugin in Phase 2.
