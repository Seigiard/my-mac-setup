# Raw agent commands

Agent commands control the recognized coding agent occupying a pane, with lifecycle validation. A child launched through `herdr-child` follows `~/.claude/shared/child-agent-contract.md`, which owns its aliases, launch environment, and supervision; this file covers the agent commands themselves.

## agent_status

- `done` — the agent finished but its tab has not been seen in the focused UI yet. Focusing marks it seen; CLI reads do not.
- `blocked` — herdr recognized an approval or question UI.
- `unknown` — does not prove completion.

## Prompt, start, and wait

- `agent prompt` atomically submits text plus Enter, honoring bracketed paste. A prompt sent while the agent is `working` is queued and runs after the current turn.
- `agent prompt` rejects an agent already waiting at an approval or question dialog with `agent_blocked`, before sending any input. Inspect the dialog with `agent read` and ask the user before answering it.
- A prompt sent from a non-working state must produce a lifecycle change within five seconds. Otherwise `agent prompt` returns `agent_prompt_stalled` instead of waiting indefinitely.
- `agent prompt … --wait` waits for the first settled `idle`, `done`, or `blocked` state. Do not repeat those defaults with `--until`.
- `agent wait <target> --until blocked --timeout 120000` performs a state-specific wait. Without `--until` it waits for `idle`, `done`, or `blocked`.
- If a wait fails or returns `blocked`, inspect `agent get` and `agent read` before deciding what to send.
- `agent start` returns only after herdr detects the agent ready for input (30-second default timeout). If the agent blocks during startup, it returns `agent_not_ready` but keeps the name usable for `agent read` and `agent send-keys`.
- Raw `agent prompt` must not continue detached work; that needs `herdr-child prompt`.

A child assembled by hand (`tab create` plus `agent start`) needs the launch environment that the contract describes under "Direct upstream launches".
