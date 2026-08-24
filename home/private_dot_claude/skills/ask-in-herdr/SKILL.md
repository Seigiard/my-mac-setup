---
name: ask-in-herdr
description: "Start a live claude, opencode, or pi peer in a herdr pane and return its answer. Use for second opinions, cross-checks, or review when HERDR_ENV=1. The pane remains available for follow-up and can call the parent through the child-agent contract."
---

# ask-in-herdr — consult a live peer agent

This skill works only inside herdr. It starts a live child through `herdr-child`, waits for the initial answer, prints the answer on stdout, and leaves the pane open for follow-up.

Read `~/.claude/shared/child-agent-contract.md` before handling a callback from the child.

## Invocation

```bash
bash ~/.claude/skills/ask-in-herdr/scripts/ask.sh <agent> "<question>" [flags]
```

`<agent>` is `claude`, `opencode`, or `pi`.

| Flag | Meaning |
|---|---|
| `--rw` | Give the child a read-write posture. The default is read-only. |
| `--model M` | Override the model. |
| `--effort L` | Set pi's reasoning effort. The default is `medium`. |
| `--cwd DIR` | Set the child working directory. |
| `--skills DIR` | Add a claude or pi skill directory. Repeat the flag for multiple directories. |
| `--agent NAME` | Select a configured opencode agent. |

The script refuses to run when `HERDR_ENV` is unset or `herdr-child` is unavailable. It has no headless mode and no `--headless` flag.

## Models and tool posture

If the caller supplies no model, opencode uses `openai/gpt-5.5` and pi uses `openai-codex/gpt-5.5`. These defaults preserve a cross-model second opinion for a claude parent.

| Agent | Read-only posture | Extra options |
|---|---|---|
| `claude` | Denies `Edit`, `Write`, `NotebookEdit`, and `AskUserQuestion`. Keeps Bash for the return channel. | `--skills` maps to `--add-dir`. |
| `opencode` | Denies `edit` and `question` through the child process environment. Keeps Bash for the return channel. | `--agent` selects a configured agent. |
| `pi` | Refused. Pi cannot keep the callback shell while withholding its write-capable shell. | Under `--rw`, excludes `ask_user`; `--skills` maps to `--skill`. |

Read-only means no file-writing tools. It is not an enforced write boundary because every started claude or opencode child keeps an unscoped shell. Filesystem containment belongs to the child sandbox work.

## Outcome contract

The answer or partial answer is on stdout only after two `herdr-child verify` calls show that the returned alias and pane resolve to the same terminal before and after capture. The wrapper never reads the agent registry directly. If either validation fails, captured output is discarded. The last stderr line is always one of these status lines:

| Status line | Exit | Meaning |
|---|---:|---|
| `ask.sh: status=answered` | 0 | The child settled at `idle` or `done`, and the answer was read. |
| `ask.sh: status=blocked` | 1 | The child settled at `blocked`. |
| `ask.sh: status=working` | 124 | The wait did not settle. The child pane remains live, and stdout can be partial. |
| `ask.sh: status=undelivered` | 1 | The pane, start, or initial prompt failed before a usable answer existed. |
| `ask.sh: status=refused` | 2 | Arguments or the requested posture are invalid. |

The script prints a pair-addressed close hint on stderr before the status line. Keep the pane for follow-up, or use the reported `herdr-child reap --to <alias> --pane <pane-id>` command.

## Examples

```bash
# Read-only opencode review.
bash ~/.claude/skills/ask-in-herdr/scripts/ask.sh opencode \
  "Review the current diff. Report only actionable findings." --cwd "$PWD"

# Read-write pi task. Pi requires --rw.
bash ~/.claude/skills/ask-in-herdr/scripts/ask.sh pi \
  "Add the missing null check and run the focused test." --rw --cwd "$PWD"

# Claude consult with an extra skill directory.
bash ~/.claude/skills/ask-in-herdr/scripts/ask.sh claude \
  "Check this herdr procedure for errors." --skills ~/.claude/skills/herdr
```

Treat a peer answer as input, not proof. Verify claims against the code and tests.
