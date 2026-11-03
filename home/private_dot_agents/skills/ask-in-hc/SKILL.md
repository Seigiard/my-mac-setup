---
name: ask-in-hc
description: "Start a live claude, opencode, or pi peer through hc when HC_TERMINAL_ID is set, return its answer, and keep the terminal available for follow-up."
---

# ask-in-hc — consult a live peer agent

This skill works in an app terminal where `HC_TERMINAL_ID` is set. It starts a peer through `hc-run`, waits with `hc wait`, reads the durable report, and leaves an answered terminal open for follow-up.

## Invocation and flags

```bash
bash ~/.agents/skills/ask-in-hc/scripts/ask.sh <agent> "<question>" [flags]
```

`<agent>` is `claude`, `opencode`, or `pi`. The script maps each agent to an `hc-run` template:

| Agent | Template | Posture |
|---|---|---|
| `claude` | `reviewer` | Read-only |
| `opencode` | `implementer-medium` | Read-write |
| `pi` | `consult-pi` | Read-write |

| Flag | Meaning |
|---|---|
| `--cwd DIR` | Set the peer working directory. |
| `--template T` | Override the mapped template. |
| `--rw` | Accepted as a no-op for `opencode` and `pi`; refused for `claude`. |
| `--close` | After an answered report, run `hc kill <address>` and then `hc rm <address>`. |

`--model`, `--effort`, `--skills`, and `--agent` are refused. A template fixes the command; use `--template` to select a different one. The skill refuses when `HC_TERMINAL_ID`, `hc-run`, or `hc` is unavailable.

## Answer transport

The launcher creates a private temporary directory and appends a `[report-transport]` block to the task. The block names `<dir>/answer.report`. The peer writes its exact complete answer to `answer.report.tmp`, renames it to `answer.report`, and returns the same answer normally. The report file is the answer; terminal screen text is evidence only.

After `hc-run --cwd <dir> <template> <task>`, the launcher waits with `hc wait --json --timeout 1800 <address>`. A missing or empty report gets exactly one bounded recovery request through `hc send --wait --timeout 120`. The transport directory is removed after settled outcomes and retained when the peer may still write; its path is printed on stderr.

If `hc-run` exits 3 because the task was not delivered, follow the exit-3 recovery rule in the `hc` skill.

## Outcome contract

Only `status=answered` puts the report on stdout. The last stderr line is the status line.

| Status | Exit | Meaning |
|---|---:|---|
| `answered` | 0 | `hc wait` settled at `idle` or `done`, or ended by exit, and the report is usable. |
| `blocked` | 1 | `hc wait` reports `blocked`; screen text from `hc read` is evidence on stdout. The transport remains. |
| `working` | 124 | `hc wait` timed out or was interrupted. Screen text is evidence and the transport remains. |
| `undelivered` | 1 | Launch, wait, or settled exit failed before a usable report. A started peer keeps the transport. |
| `refused` | 2 | The gate, arguments, agent, or posture is invalid. |
| `no-report` | 3 | No report exists after the one recovery request. |
| `empty-report` | 4 | The report is empty after the one recovery request. |
| `bad-report` | 5 | The report is not a regular file or is a symlink. It is never read. |

For an answered terminal left open, stderr includes:

```text
ask.sh: consult is in hc terminal <address> (<alias>) (left open; close with: hc kill <address>; hc rm <address>)
```

## Follow-up

Send an ordinary follow-up with:

```bash
bash ~/.agents/skills/ask-in-hc/scripts/follow-up.sh <address> "<text>" [--wait] [--force]
```

The wrapper runs `hc send <address> <text>`. With `--wait`, it adds `--wait --timeout 1800`; with `--force`, it adds `--force`. A successful send reports `status=delivered`. A wait timeout reports `status=working` with exit 124. An `hc` exit status of 9 reports `status=blocked`; use `--force` only when the screen confirms that typing is safe. Other delivery failures report `status=delivery-unknown`.

## Cleanup

Only clean up terminals started by this skill. Check the child with `hc get <address>` before acting. Once no continuation is needed, run `hc kill <address>` and then `hc rm <address>`. Follow the cleanup guard in `~/.claude/shared/hc-agent-contract.md`: never kill a terminal whose status is `working` or `blocked`.

The existing `ask-in-herdr` skill remains the TUI path. Both skills coexist until the TUI retires.
