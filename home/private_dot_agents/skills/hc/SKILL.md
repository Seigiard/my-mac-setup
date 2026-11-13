---
name: hc
description: "Drive hc (herdr-core) in Herdr app terminals. Use when starting, steering, waiting on, or cleaning up a child or peer agent with hc, or when HC_TERMINAL_ID is set."
---

# hc — agent control skill

Before doing anything, confirm you are inside an hc terminal:

```bash
test -n "${HC_TERMINAL_ID:-}"
```

If the check fails, say you are not running inside an hc terminal and stop.

Read the installed manuals before using the tools:

- `hc --skill` covers terminals, agents, messages, waits, and cleanup.
- `herdr-app --skill` covers only what the person sees. Use it for spaces, tabs, and panes.
- The agent contract is `~/.claude/shared/hc-agent-contract.md`.

Start children with the launcher. It runs in the background by default:

```bash
hc-run <template> "<task>"
```

If `hc-run` exits 3, it prints the child address and a diagnostic. Treat exit 3 as unconfirmed delivery or start, not as permission to resend. Inspect `hc get --json <address>` and `hc read --json <address>` first. If the child is working, wait for it. Keep a blocked child running and defer trust, permission, or other human decisions to the person; do not accept a permission dialog with a blind key. For `hc-run: task not sent: hc read <address>`, resolve a visible readiness problem and send the template body from `~/.config/herdr-core/templates/<name>.md` after its frontmatter, followed by the task; check the send result and never resend without reading the screen again. For `hc-run: task sent but not started: hc read <address>`, do not send the task again. `hc-run` may have tried one `enter` after it observed a task draft without a blocking dialog; it does not claim that it tried `enter` when no draft was visible or a dialog blocked it. If an idle child has no pending human decision and readiness cannot be resolved, run `hc kill <address>` and `hc rm <address>`, then restart with `hc-run`.

Use `--tab` only when the person asks to see the child. Templates live in
`~/.config/herdr-core/templates/`; list them with `hc templates`.

## Second opinion

For Claude or OpenCode, run `hc-run reviewer|implementer-medium "<question>"`.
Then run `hc wait --json --timeout <s> <address>`. Read the answer from an
`<hc from>` message or with `hc read <address>`. Report blocked or exited states
from the core notes.

For pi, run it directly without a template:

```bash
hc run --bg --json --name <name> --cwd <dir> -- pi --model openai-codex/gpt-5.5 --thinking medium --exclude-tools ask_user
hc wait <address>
hc send --json <address> "<task>"
```

Check `sent` in the send result. Prepend the contract pointer when the consult
must report back. If `sent` is false, run `hc read <address>` first and resolve
readiness. A trust dialog may need `hc keys <address> down enter`. Do not
blindly resend after a failed send: the message may still have arrived.

Clean up idle, exited, or done terminals with `hc kill <address>` and then
`hc rm <address>`. Keep working or blocked terminals running.
