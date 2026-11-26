# Security policy

Claude Code Companion can approve Claude Code permission prompts, so a security bug here can let a command run that you never agreed to. Please report those privately.

## Reporting a vulnerability

Use [Report a vulnerability](https://github.com/lfb0801/claude-companion/security/advisories/new) on the repository's Security tab. Don't open a public issue for it.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get a reply within a week. Once a fix is out, the advisory is published with credit to you, unless you'd rather stay anonymous.

## What counts

In scope:

- Anything that lets another program, website, device or user answer a prompt, read a session, or send text to a session without your say-so. That includes the local server on `127.0.0.1:5173` (its Host and Origin checks), the `companion-stage` plugin and its hooks, and the iPhone link (pairing, authentication, replay).
- The overlay or the plugin running something other than what the prompt showed.
- Secrets or transcript content leaking out of your machine.

Out of scope, because they are documented behaviour (see Known risks in the [README](README.md)):

- The Approval Intern and the cannon approving whatever they hit.
- Other programs running as your own user calling the local server.
- Changes in Claude Code's undocumented transcript format.

## Supported versions

Only the latest commit on `master` gets fixes.
