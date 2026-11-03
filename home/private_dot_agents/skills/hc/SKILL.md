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

If `hc-run` exits 3 because the task was not delivered, it still prints the child address. Run `hc read <address>`, resolve readiness (for a trust dialog, `hc keys <address> down enter`), then send the template body from `~/.config/herdr-core/templates/<name>.md` after its frontmatter, followed by the task. For `ask-in-hc`, use the task file whose path `ask.sh` prints as `task kept at`. If readiness cannot be resolved, run `hc kill <address>` and `hc rm <address>`, then restart with `hc-run`.

Use `--tab` only when the person asks to see the child. Templates live in
`~/.config/herdr-core/templates/`; list them with `hc templates`. Use `ask-in-hc` for a
peer's answer.

The `herdr` skill remains the TUI path. Both skills coexist.
