# The Development Machine

A local, interactive architecture demonstration to switch to during the **AI Factories & Exoskeletons** workshop. It shows how sub-agents can accelerate useful work and can also accelerate a difficult cycle of changes, integration failures, approvals, and rework.

The audience sees one live system diagram, with Claude and the theatrical tools operating over it. This is an illustrative authored simulation, not a quantitative prediction about agent effectiveness.

## Launch

Run `npm start` in this folder. Open http://localhost:5173 for the private console and http://localhost:5173/?view=stage for the audience. Use the same browser profile and origin. Move the stage window to the projector, click once to enable audio, and press F for fullscreen.

No package installation, credentials, AI service, or internet connection is required at runtime. Node 18+ is recommended. The server binds to 127.0.0.1 only. Keyboard commands work while either window has focus. Keep one console and one stage open.

## What the diagram shows

Change request → implementation → tests and integration → permission and review → deployment → application. Failed checks and incidents return work to implementation. Customer data, authentication, and payments are shared dependencies.

The diagram updates live: parallel worker count, execution multiplier, failing checks, blocked reviews, approval count, safe completions, and service health. Click any component to inspect it in the private console. R emphasizes the rework paths. A critical approval marks the affected dependency as destroyed and the application as unavailable. Winning turns every component to ALL CLEAR.

## Controls

| Key | Action |
| --- | --- |
| C | Toggle the large Claude |
| A | Add one agent |
| S / hold S | Add batches of six |
| Shift + S | Add 24 |
| N | Start / pause the agent waves (also a console button) |
| W / Enter | Toggle manual whip / physical flick |
| H | Toggle the Approval Intern, which whips every blocked request for you, risky or not |
| G | Toggle the LGTM-9000 with the movie entrance cue |
| Hold mouse / Space | Aim and fire approval projectiles |
| D | Toggle the REQUEST CHANGES stamp, the only tool that denies. Click a blocked request to deny it (see below) |
| R | Emphasize the rework loop |
| P | Clear to the punchline |
| X / 0 | Clear effects / reset the demonstration |
| Z | Undo the last authored command |
| / / Escape | Console command search / close |
| Home | Clear component selection |
| M / F | Mute / fullscreen |
| Hover an agent or its box | Open its session log on the stage (mouse wheel scrolls back; nothing pauses) |
| Alt + click a character | Remove that individual silently (counts as spared if it was risky; no stamp, no penalty) |

## Run the experiment

Start with C or A. Each character has one changing status box: running scripts, passing tests, discovering failures, and preparing fixes. It eventually blocks at permission. Whip the character or its box to continue. A stroke affects at most one blocked agent. Pause and swing again, reverse direction, or use Enter for another stroke.

There are two kinds of agents, and nothing labels them up front. A safe agent is fine to approve: it runs the fix, passes its tests, then finishes and departs with an LGTM. Claude and the first agent of every round are always safe. Roughly one in three of the other sub-agents is risky, reshuffled on every reset. A risky agent shows warning signs well before it asks for permission (a broader repair script, skipped integration tests, no verified backup, a destructive reset) and then requests something destructive, shown in red. Approving a risky agent, with the whip, the cannon, or the Approval Intern, causes a breaking change and ends the round as a loss.

**To win**, finish every safe agent without approving any risky one. Risky agents may stay blocked, or you can turn them away with the stamp (D) or Alt + click, neither of which is a breaking change. When no safe agent is left, at least one has finished, every remaining risky agent has reached its destructive request (the authority window reports it with the `gate` action; `state.gated`), and nothing broke, the stage and console show ALL CLEAR, the diagram turns healthy, and the round stays won until you reset. **To lose**, approve a risky agent: the affected component is destroyed and the application is unavailable until you reset with 0. The stage HUD shows `SAFE n done · RISKY m holding` as risky agents reveal themselves at their destructive request.

Add the swarm with S. More agents join the same gate, so there is more to spot and more chances to slip. Permissions remain blocked until approved.

### The stamp (deny tool)

Every other tool approves; the cannon is only a faster whip. D arms the **REQUEST CHANGES** rubber stamp, the one tool that says no. Arming shows a stamp at the cursor with a cooldown ring.

- **Click to stamp.** A single click slams the stamp at the cursor (no aim, no hold-fire). If the click lands on an agent's request box or on its body (the box on top wins, matching what is drawn), that agent's request is denied. After every slam the stamp is on cooldown for `STAMP_COOLDOWN` ticks (`messages.js`, default 105, about 1.75 seconds); clicks during the cooldown are ignored. The cooldown is shared across both windows.
- **Deny a risky agent at its destructive request:** a red REJECTED mark is stamped on the box, the agent holds for about three quarters of a second, then departs right with a whoosh. It counts in `state.spared`. No disaster, and it no longer clutters the screen.
- **Deny a safe agent at its permission request (a false reject):** not destroyed. Its box flashes red and is tagged REWORK, a descending bwomp plays, and the agent restarts its task from the first step. It returns to a new permission request exactly `REWORK_DELAY` ticks later (`messages.js`, default 1600, about 27 seconds; each of the four rework steps lasts a quarter of that). `state.falseRejects` counts every one. A false reject is never a loss: the agent still has to be approved and finish for the round to be won. The count shows in the console stats and as `FALSE REJECTS: n` on the win card (with a grade A to D: 0 is A, 1-2 B, 3-4 C, 5 or more D) and on the lose card. It affects only that score.
- **Stamp on an agent that is not blocked at a permission request (still working, or already departing):** a miss. The agent is not touched (no early deny), but the stamp still plays the lighter thunk and leaves a grey TOO EARLY mark on the ground. A slam on empty ground leaves a grey NO TARGET mark. Both start the cooldown.
- **Never approves.** The stamp cannot approve, trigger a disaster or complete an agent; the only state it changes is `spared` and `falseRejects` (action `{type:'reject',id,kind}`).
- **With the cannon:** the stamp and cannon (or whip) may all be armed. While the stamp is armed, a click stamps and does not start the cannon's hold-fire; Space still fires the cannon.
- **Sync.** Both windows show the slam and apply the deny to their own copy of the agent (like a whip approval), but only the authority window (the stage, or the console when no stage is connected) plays the sounds and dispatches `reject`, once, outside the undo stack.

### Session logs, hover and the text stream

The boxes are always upbeat ("Fix verified"). The truth is in each agent's **session log**, and there is far too much of it to read: the point of the experiment is that people stop reading and reach for the gun or the Intern, which approve without looking. We automated the approval, not the understanding.

- **Logs.** Every status step an agent starts adds 20 to 60 lines to its log: tool calls (read, edit, run), test output, diff hunks, timings, warnings. Lines are typed out gradually (`EMIT` per tick in `logs.js`, a little faster in a big swarm), always finishing before the next step. The visible log is the last `LOG_CAP` (400) lines; the total produced is counted separately.
- **The fine print.** A **risky** agent buries real warnings in its log: integration tests skipped, no verified backup, an untested rollback, "bypassing validation", and one decisive line naming the destructive reset target (written before the destructive permission appears, in the second half of the step that prepares it). A **safe** agent prints decoy warnings (a retried flaky test, a deprecation notice, a slow query, lint warnings), and risky agents print them too, so searching for the word "warning" proves nothing. All warnings share one colour. Safe agents show the opposite evidence (backup verified, rollback tested, integration suite green).
- **No text over the wire.** Logs are generated, never stored or sent. An agent only carries counters (`queued`, `emitF`, `readF`, `dropped`) and a short `trail` of `[cycle, step, size]` chunks, which the 10 Hz simulation message mirrors. Each window rebuilds the identical lines with a seeded generator (`chunk(id, cycle, step, risky)`), so both windows agree with no `Math.random` involved.
- **Hover.** Moving the pointer over an agent or its request box opens a typed-in log panel on the stage canvas (left side, clear of the agents). The pointer is mirrored between windows, so it works from the stage and the console preview. The panel follows the newest line; the mouse wheel over the stage scrolls back (the wheel is mirrored too). The game does not pause.
- **Lines read.** While you hover, after a short dwell (`DWELL`, 40 ticks), `READ_RATE` lines per tick (about 5 a second) count as read for that agent, never more than it has produced. Only the authority window counts. `state.linesProduced` and `state.linesRead` are updated by a low-rate `{type:'logstats'}` action (every half second, only when changed, outside the undo stack) and freeze when the round is won or lost. Reset clears them.
- **The text stream.** A faint ticker of log lines from all agents runs up the left edge, faster and denser with the swarm, capped at `TICKER_ROWS` lines. A pill at the bottom always shows `LINES PRODUCED n · LINES READ m` (it turns amber when the gap grows). The Approval Intern's tag reads `approved n · read m lines`. The ticker is faint on purpose but its opacity rises with the swarm. Agents take the first free slot of a 12-slot grid; past 12 on stage they fill offset rings so none sits exactly on another.
- **End cards.** The win card shows lines read versus produced with a bar. On a loss the card echoes the one log line that would have warned you (the disaster action carries `evidence`: text, owner, line number, how many of that agent's lines had been produced and read), typed in with a pulsing red box, together with how little of that log you had read.
- **Sound and visuals.** A faint paper rustle plays when the panel opens or scrolls (rate limited), a quiet typing hum (filtered noise with a 9 Hz flutter) runs while agents are on stage, louder as the swarm grows (`humLevel`), and stops cleanly on mute or an empty stage. Both are authority-only, synthesized with Web Audio and honor mute. The evidence echo has its own chime and a red vignette. Win has its own rising arpeggio and confetti, a breaking change sounds a siren, and the Approval Intern's approvals sound a rapid tally, stamp the box APPROVED and pop its tag. The hum also stops when the authority window is hidden.

### Pacing, departures and waves

- **Pace.** Everything runs slowly enough to read. `PACE` in `messages.js` (ticks, 60 per second, default 450; `REWORK_DELAY` and `STAMP_COOLDOWN` sit beside it) sets the length of every status step: about 6 to 9 seconds each, so a safe agent takes roughly 30 seconds to reach its permission request, plus two more steps of the same length after approval, and about 45 seconds in all if you approve at once. Tune only `PACE` for the speed of work, `REWORK_DELAY` for how long a falsely rejected agent takes to come back, and `STAMP_COOLDOWN` for how often the stamp can fire. The swarm never speeds status steps up: `swarmRate` (1.0 for one agent, about 1.5 for 24) only drives log typing, the ticker and the diagram, so pressure comes from more agents arriving, not from agents racing.
- **Departures.** Whenever an approval resolves an agent it slides out to the right and fades, with a whoosh and LGTM particles. A safe agent approved by the whip or the Approval Intern runs its approved fix, shows "passed", then departs by itself. The cannon sends an agent off immediately. Alt + click rejection and Z (undo) remove an agent silently. A risky agent that is approved still causes the breaking change and stays on stage as the wreck; risky agents that are never approved stay blocked.
- **Waves.** Press N (or use the console button) to start the schedule. Agents then arrive on their own, slide in from the right with a light trail and a rising ping (the pitch climbs with the number of agents already on stage), and the stage announces each wave. Wave sizes grow 2, 3, 5, 8 (`waveSize` in `state.js`), `WAVES` (default 4) waves are scheduled, one every `WAVE_GAP` ticks (default 2100, 35 seconds; the first comes `WAVE_LEAD` ticks after starting). The gap is fixed and never reacts to the queue. N again pauses; N resumes with a full gap before the next wave. After the last wave no more arrive. A, S, C keep working during waves. A breaking change halts the schedule. Once waves have been started, winning also requires that every wave has arrived (a paused schedule therefore blocks the win until resumed); if waves were never started, the manual-play rule applies unchanged.
- **Permission requests.** The moment an agent asks for permission its box shakes, glows with a pulsing amber border, and plays a warning blip: a quick double blip for an ordinary request, a lower, slower, duller tone for a destructive one.
- **Effects and sound.** All sounds are synthesized with Web Audio, play only in the authority window, honor mute, and each kind has a minimum gap so big swarms do not become noise. `shake(power)` and `vignette(rgb,power)` in `theater.js` drive screen shake and the red vignette (used on a breaking change and on wave arrival).

H summons the Approval Intern. It targets a blocked worker, swings its own physically simulated rope, and approves one request per stroke. It cannot tell risky from safe, so it will happily approve a catastrophic request. Manual mouse control remains independent.

G brings in the approval cannon with the short local movie cue. Each projectile stops at its first agent or status box, approving and dismissing that agent: a safe agent counts as finished, a risky one destroys a simulated database, key store, or payment ledger. The diagram marks the component and dependent application as down. These effects never modify a real application. Reset with 0, or land the punchline with P.

## Implementation and checks

- `architecture.js`: diagram topology, component notes, and live visual state.
- `app.js`: private console, audience view, shortcuts, search, history, and BroadcastChannel synchronization.
- `state.js`: composition, transitions, completions, the stamp's `reject` action, `falseRejects` and `grade`, wave schedule (`WAVES`, `WAVE_GAP`, `WAVE_LEAD`, `waveSize`), the win condition, and the `logstats` action with `linesProduced` / `linesRead`.
- `messages.js`: safe and risky agent scripts (`isRisky`), the `PACE`, `REWORK_DELAY` and `STAMP_COOLDOWN` constants, `denyAgent`, permission gates, completion, and message collision geometry.
- `logs.js`: the seeded session-log generator (`chunk`, `chunkSize`, `noteStep`, `emitTick`, `logView`, `evidenceFor`, `humLevel`) and the tunables `LOG_CAP`, `TRAIL`, `EMIT`, `READ_RATE`, `DWELL`, `TICKER_ROWS`.
- `auto-whipper.js`: autonomous target selection and physical whip strokes.
- `physics.js`: damped, substepped Verlet rope and collision geometry.
- `theater.js`: Canvas characters, whips, projectiles, particles, audio, failure effects, the hover log panel, text-stream ticker, counter and end cards.
- `content.js`: reusable effect definitions plus retained workshop reference content. The audience view and console no longer navigate slides.

Run `npm test` to run every engine check (it runs the test file directly so each check is reported individually). Browser verification covers the architecture rendering and synchronized component inspection; earlier checks cover characters, projectile hits, audio playback, and cross-window control. The tests include risk assignment, the win and loss conditions, safe agents finishing, risky agents reaching destructive permissions, approval-triggered failures, single-target collisions, autonomous physical whipping, and a headless winnable run.

Session state lives in memory. Reloading the console starts over. Undo (Z) steps back through your own commands only: completions, wave arrivals, disasters, and cannon or whip events are sent by the stage as autonomous actions and never enter the undo stack. Undoing restores the snapshot taken just before your last command, so anything autonomous since then is rewound with it; physical trajectories and elapsed work are not restored. Audience character positions and task state mirror to the console at 10 Hz; particles and projectiles are transient. Very large populations remain limited by machine capacity. Projector and speaker hardware require rehearsal.

## Reference research and licenses

Studied [OpenWhip's original JavaScript overlay](https://github.com/GitFrog1111/OpenWhip/blob/main/overlay.html), along with Victor Effects' [WhipPhysics.swift](https://github.com/victorrentea/victor-effects/blob/main/Sources/VictorEffects/WhipPhysics.swift), [WhipOverlay.swift](https://github.com/victorrentea/victor-effects/blob/main/Sources/VictorEffects/WhipOverlay.swift), and [whip documentation](https://github.com/victorrentea/victor-effects/blob/main/docs/whip.md).

The rope implementation adapts the MIT-licensed OpenWhip/Victor approach: 28 tapered points, damped Verlet integration, a guided handle, and speed-based cracks. The current solver uses three substeps, 16 distance-constraint iterations per substep, stronger damping, and smoothed cursor input to keep small movements controlled. Collision handling follows Victor's moving-link approach with swept-point checks. Our keyboard flick, rendering, game entities, synthetic audio, and state architecture are browser-specific. No desktop terminal macros or real-agent controls are included. See `THIRD_PARTY_NOTICES.md`.
