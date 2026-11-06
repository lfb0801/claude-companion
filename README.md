# Claude Code Companion

A stage that watches your Claude Code sessions. When a session needs you (a permission prompt, a question, a plan to approve, or a finished turn) its character walks on stage with the prompt beside it. Answer from the stage with the whip, the cannon, the Approval Intern or the stamp, or click the prompt for a proper card. Launch new sessions, each in its own terminal drawer.

Everything runs on your machine: a Node server on `127.0.0.1:5173`, a Claude Code plugin that reports to it, and one browser page.

## Setup

Requires Node 18+, tmux, and Claude Code 2.1.319 or later.

```sh
npm install        # node-pty, ws and xterm.js for the terminal drawer
npm start          # http://localhost:5173
```

Install the plugin from this repository, inside Claude Code:

```
/plugin marketplace add /path/to/claude-companion
/plugin install companion-stage@companion
```

New sessions report to the companion from then on. Open http://localhost:5173 and click once to enable sound. `http://localhost:5173/?demo` shows three fake sessions without the server or plugin.

## How answering works

| Prompt | On stage | Answered in the terminal |
| --- | --- | --- |
| Tool permission | Held until you answer here or in the terminal, whichever comes first | The character leaves |
| Question (AskUserQuestion) | Answered only here while the page is open; the terminal shows no dialog | Esc in the terminal cancels it |
| Plan (ExitPlanMode) | Approve, or keep planning | The character leaves |
| Finished turn | "Waiting for you"; dismiss it, or open the terminal | A new prompt clears it |

With no page open, nothing is held: every prompt goes to the terminal as usual. Closing the last page hands held prompts back to the terminal.

## Controls

| Key | Action |
| --- | --- |
| W / Enter | Whip: approves what it hits / crack it |
| G, then Space or hold the mouse | Cannon: fires approvals at whatever it hits |
| D, then click | Stamp: denies the prompt it lands on |
| H | Approval Intern: approves every prompt, in every session |
| S | Session list, including sessions that are off stage |
| L | Launch a session in a project, with an optional first prompt |
| Click a prompt (no tool armed) | Prompt card: allow / deny, pick answers, approve a plan |
| Click a character (no tool armed) | Its terminal drawer, or "Resume here" |
| Hover a character (no tool armed) | Its recent transcript |
| M / F / Esc | Sound / fullscreen / close |

Launched sessions run in tmux as `cc-<session id>`. They survive server restarts, and `tmux attach -t cc-<id>` reaches them from any terminal.

## Known risks

These are accepted for a personal tool on your own machine. Read them before turning the Intern on.

- **The Intern approves anything,** including destructive commands, in every session. Only `permissions.deny` rules in your Claude Code settings still stop it. A stray cannon shot approves whatever it hits.
- **No login.** The server refuses requests from other websites and other local ports (Origin and Host checks), but any program on your machine can call it.
- **"Resume here" can run two processes on one session** if you ignore its warning.
- **Transcript format.** The hover log and terminal-answer detection read Claude Code's transcript JSONL, which is undocumented and may change.
- `assets/audio/little-friend.mp3` is a film clip. Making this repository public would need it removed from history.

## Layout

| Path | What |
| --- | --- |
| `plugin/` | The `companion-stage` plugin: HTTP hooks to `/ingest`, and `hooks/ask.ts`, a mod that answers AskUserQuestion from the companion |
| `server.mjs` | HTTP server: `/ingest`, `/events` (SSE), `/answer`, `/log`, `/ask` |
| `companion.mjs` | Session state and held prompts |
| `transcript.mjs` | Transcript parsing and tailing |
| `launcher.mjs` | tmux launch, recent projects, resume, terminal WebSocket |
| `app.js`, `theater.js`, `state.js` | The page and the stage |
| `drawer.js`, `launch-panel.js` | Terminal drawer and launch form |
| `spike/` | Phase 0 spike: hook behaviour findings and recording tools |
| `tests/` | `npm test`: replays recorded hook payloads and transcripts in `tests/fixtures/spike/` |

Third-party notices are in `THIRD_PARTY_NOTICES.md`.
