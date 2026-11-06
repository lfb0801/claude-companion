<div align="center">

<img src="assets/claude/happy-0.png" width="150" alt="Happy Claude" />&nbsp;&nbsp;
<img src="assets/claude/scared-0.png" width="150" alt="Scared Claude" />&nbsp;&nbsp;
<img src="assets/claude/dizzy-0.png" width="150" alt="Dizzy Claude" />

# Claude Code Companion

**Your Claude Code sessions, performing on your desktop, waiting for your applause.**

A native macOS overlay that watches every Claude Code session you have running.<br />
When one needs you, its character walks on stage. Answer with a whip, a stamp, a cannon, or an intern.

<img src="docs/overlay.png" width="460" alt="Three sessions waiting on the stage, each with its permission prompt" />

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-native-F05138?logo=swift&logoColor=white)
![Node 18+](https://img.shields.io/badge/Node-18%2B-5FA04E?logo=nodedotjs&logoColor=white)
![Claude Code 2.1.319+](https://img.shields.io/badge/Claude%20Code-2.1.319%2B-D97757)
![Runs locally](https://img.shields.io/badge/runs-100%25%20local-2ea44f)
![License](https://img.shields.io/badge/license-MIT-blue)

</div>

<br />

## ✨ What it does

Claude Code stops and waits for you more often than you notice. A permission prompt in a buried terminal tab, a question, a plan to approve. The Companion puts all of it on one transparent, click-through stage over your desktop, so nothing waits unseen.

| | |
| --- | --- |
| 🎭 **One character per session** | They walk on when Claude needs you and leave once you have answered, in the terminal or on stage. |
| 🃏 **Cards, not dialogs** | Click a prompt and its options are dealt as cards on the desktop. Left-click picks, right-click flips a card to write a note on its back. |
| 🪢 **Tools you can play with** | Approve by cracking the whip. Deny with the stamp. Fire approvals with the cannon. |
| 🧑‍💼 **The Approval Intern** | Approves every prompt in every session while you get on with your day. Use with care. |
| 🔒 **Local only** | A Node server on `127.0.0.1:5173`, a Claude Code plugin that reports to it, and the Swift overlay. Nothing leaves your machine. |

## 🚀 Get started

You need macOS 14+, Node 18+, Xcode command line tools, and Claude Code 2.1.319 or later.

**1. Build and launch the overlay**

```sh
mac/build-app.sh --open
```

This builds `mac/build/Claude Companion.app`, a menu bar app with no Dock icon. It starts the Node backend from this repository if it is not already running.

**2. Install the plugin**, inside Claude Code:

```
/plugin marketplace add /path/to/claude-companion
/plugin install companion-stage@companion
```

New sessions report to the Companion from then on. That's it.

> [!TIP]
> Prefer to run only the backend? `npm start` serves it on `http://localhost:5173`.

## 🎮 Your tools

Global hotkeys work from any app and need no Accessibility permission.

| Hotkey | Tool | What it does |
| :---: | --- | --- |
| <kbd>⌃⌥</kbd> <kbd>W</kbd> | 🪢 **Whip** | Swing the mouse to lash a prompt and approve it. Hold the whip and click to stamp with the back of the handle. |
| <kbd>⌃⌥</kbd> <kbd>D</kbd> | 🔖 **Stamp** | Click a prompt to deny it, or request changes. |
| <kbd>⌃⌥</kbd> <kbd>G</kbd> | 💥 **Cannon** | Fires approvals at whatever it hits. |
| <kbd>⌃⌥</kbd> <kbd>H</kbd> | 🧑‍💼 **Approval Intern** | Approves everything, everywhere. |
| <kbd>⌃⌥</kbd> <kbd>X</kbd> | 🧹 Put tools away | Disarm whatever you are holding. |
| <kbd>⌃⌥</kbd> <kbd>M</kbd> | 🔊 Sound | On or off. |
| <kbd>⌃⌥</kbd> <kbd>T</kbd> | 🧰 Toolbar | Bring the floating toolbar back. |

**No tool in hand?** Click any prompt to deal its cards. Hover a character to read its recent transcript.

## 🔀 How answering works

| Prompt | On stage | If you answer in the terminal first |
| --- | --- | --- |
| **Tool permission** | Held until you answer here or in the terminal, whichever comes first | The character leaves |
| **Question** (`AskUserQuestion`) | Options dealt as cards. The terminal shows no dialog while the stage is up | <kbd>Esc</kbd> in the terminal cancels it |
| **Plan** (`ExitPlanMode`) | A plan sheet with *Approve* and *Keep planning* | The character leaves |
| **Finished turn** | A brief "waiting for you" that leaves by itself | A new prompt clears it |

With the overlay closed, nothing is held: every prompt goes to the terminal as usual. Quitting hands any held prompts back to the terminal.

## ⚠️ Known risks

Accepted for a personal tool on your own machine. Read them before you turn the Intern on.

- **The Intern approves anything,** destructive commands included, in every session. Only `permissions.deny` rules in your Claude Code settings still stop it. A stray cannon shot approves whatever it hits.
- **No login.** The server refuses requests from other websites and other local ports (Origin and Host checks), but any program on your machine can call it.
- **Transcript format.** The hover log and terminal-answer detection read Claude Code's transcript JSONL, which is undocumented and may change.
- **Audio.** `assets/audio/little-friend.mp3` is a film clip, and `assets/audio/whip-summon.mp3` is the first 0.65 s of "cool hwhip" from myinstants.com, a user upload with no stated licence. Making this repository public would need both removed from history.

## 🗺️ Under the hood

```mermaid
flowchart LR
    CC["Claude Code sessions"] -- "hooks" --> P["companion-stage plugin"]
    P -- "POST /ingest" --> S["Node server<br/>127.0.0.1:5173"]
    S -- "SSE /events" --> O["Swift overlay<br/>(Claude Companion.app)"]
    O -- "POST /answer" --> S
    S -- "allow / deny / answers" --> CC
```

| Path | What |
| --- | --- |
| `mac/` | The native overlay: AppKit and CoreGraphics. `StageCore` holds the logic, `Companion` draws the stage |
| `plugin/` | The `companion-stage` plugin: HTTP hooks to `/ingest`, plus `hooks/ask.ts`, a mod that answers `AskUserQuestion` from the Companion |
| `server.mjs`, `companion.mjs` | HTTP server and session state, including held prompts |
| `transcript.mjs` | Transcript parsing and tailing |
| `app.js`, `theater.js`, `state.js` | The original browser stage. `/?demo` shows three fake sessions without the server or plugin |
| `spike/` | Phase 0 spike: hook behaviour findings and recording tools |
| `tests/` | `npm test` replays recorded hook payloads and transcripts from `tests/fixtures/spike/` |

Third-party notices are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

<div align="center">
<br />
<sub>Made for people who run more Claude sessions than they have terminal tabs.</sub>
</div>
