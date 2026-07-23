---
name: ask-agent
description: "Ask another coding agent — opencode, pi, or claude — a one-shot question and get its answer back: a second opinion, a code review, or independent verification from a peer. Use when the user says ask/consult opencode/pi/claude, wants a second opinion or cross-check from another agent, or when you want a peer agent to review your work. Read-only by default (the asked agent answers, does not edit)."
---

# ask-agent — consult a peer agent

Run another coding-agent CLI as a one-shot, hand it a question, and get its answer back. By default it is a **read-only consult**: the asked agent answers or reviews but does not edit files.

All invocation logic lives in scripts (not inline here), because each agent loads its skills/context differently and the argument-building is agent-specific. You call one entrypoint:

```bash
bash ~/.claude/skills/ask-agent/scripts/ask.sh <agent> "<question>" [flags]
```

- `<agent>` — `claude`, `opencode`, or `pi`.
- Returns the agent's answer on stdout.

## Modes (auto-detected)

- **Inside herdr** (`HERDR_ENV=1`): the consult runs in a **visible herdr pane** beside you — you watch it live, and the pane stays open so you (or the user) can follow up in it. Its output is still captured back to stdout.
- **Outside herdr**: runs as a **headless subprocess**; stdout is the answer.
- `--headless` forces the subprocess path even inside herdr (no pane).

## Flags

| Flag | Meaning |
|------|---------|
| `--rw` | allow the asked agent to edit files (default is read-only consult) |
| `--model M` | model override (agent-native format, e.g. `openai-codex/gpt-5.5` for pi, `provider/model` for opencode) |
| `--effort L` | reasoning effort for **pi** only: `off\|minimal\|low\|medium\|high\|xhigh` (default `medium`) |
| `--cwd DIR` | working directory / project context for the consult |
| `--skills DIR` | add an extra skill directory (repeatable; only `pi` and `claude` honor it — see below) |
| `--agent NAME` | opencode only: pick a configured opencode agent |

**Default model.** Both `pi` (`openai-codex/gpt-5.5`) and `opencode` (`openai/gpt-5.5`) default to **GPT-5.5** — a genuine *cross-model* second opinion (different family than `claude`, which runs its own Anthropic model). pi additionally applies `--effort medium`; opencode's reasoning variant is left at its default (`--effort` applies to pi only). Override any agent's model with `--model`.

## Skills & read-only per agent

Each agent keeps **all of its own skills** by default (discovery stays on); we never strip an agent down to bare. How extra skills and read-only are wired differs:

| Agent | Extra skills (`--skills`) | Read-only enforcement |
|-------|---------------------------|------------------------|
| **claude** | auto-loads `~/.claude/skills`+`CLAUDE.md`; `--skills DIR` → `--add-dir` | `--allowed-tools Read Grep Glob WebFetch WebSearch` — read, search, **web**; **cannot** Bash/Edit/Write (verified) |
| **pi** | auto-discovers its own skills; `--skills DIR` → native `--skill` (repeatable) | `--tools read,grep,find,ls` — read + search; **no** bash/edit/write (verified). No built-in web (extension only). |
| **opencode** | loads its own config/agents; `--skills` ignored (no flag); `--agent` picks one | **prompt preamble only (interim).** opencode 1.17.5 has no per-call `--permission`; hard read-only needs a read-only **agent** in `opencode.json` selected via `--agent`. |

**Read-only allows web, not shell.** Read-only denies Bash/Edit/Write, so a consult **cannot run `git`, tests, or builds** — but it *can* read, search, and (claude) reach the web (`WebFetch`/`WebSearch`) to check docs/facts. If the agent needs a diff or test output, **pipe it into the question** (see examples) or pass `--rw`. Note: excluding only edit/write is NOT read-only — `bash echo > file` slips through; that is why read-only uses an allowlist.

## Examples

```bash
# Second opinion from pi, read-only:
bash ~/.claude/skills/ask-agent/scripts/ask.sh pi "Is this regex catastrophic-backtracking safe? $(cat pattern.txt)"

# Review the staged diff — pipe it in, because a read-only consult can't run git itself:
bash ~/.claude/skills/ask-agent/scripts/ask.sh claude "Review this diff for bugs. Verdict APPROVE or CHANGES:

$(git diff --cached)"

# Ask claude to do herdr work, giving it the herdr skill explicitly:
bash ~/.claude/skills/ask-agent/scripts/ask.sh claude "How do I split a pane and wait for a server?" --skills ~/.claude/skills/herdr

# Let pi actually apply a small fix (read-write):
bash ~/.claude/skills/ask-agent/scripts/ask.sh pi "Add a missing null check in src/api/load.ts" --rw --cwd "$PWD"
```

## Using the answer

- The answer is on stdout — read it, then **verify before trusting it** (check the claim against the code/tests yourself; a peer agent's "done"/opinion is input, not proof).
- **opencode** prefixes its output with a banner line (e.g. `> Sisyphus · model`); the answer follows it. Ignore the banner.
- In herdr mode the consult pane is left open; close it with `herdr pane close <pane_id>` (the id is printed on stderr when the consult finishes) or keep it to continue the conversation there.

## opencode sandbox

opencode one-shots (`run --dir <cwd>`) reject reads outside `--cwd`; non-interactive they **exit silently with no output** instead of asking. Stage files the consult must read into cwd, or add a scoped glob to `~/.config/opencode/opencode.json` → `permission.external_directory` (existing entries: `/tmp/ce-doc-review/**`, `~/.claude/skills/**`). Never assume a bare `/tmp` or `~/...` path is readable. Also: smithers drops `smithers.db*`/`.smithers/` into its launch cwd — launch it from a tooling dir, not the repo.

## Notes & limits

- Read-only is enforced by a tool **allowlist** for claude and pi (no Bash, so no writes at all), but only by **prompt** for opencode (not a hard guarantee). Use `--rw` when you want the agent to make changes.
- `--cwd`/`--skills` paths with spaces are fine (ask.sh shell-escapes values for the herdr-pane path).
- This skill consults agents that are installed and on PATH: `claude`, `opencode`, `pi`. A missing CLI fails fast.
