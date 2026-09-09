# Skill eval isolation

A PATH shim that runs `claude` with the operator's own configuration switched
off. It exists so that `agent-skill-eval` measures a skill rather than this
machine.

This is a spike. Nothing here is wired into any `make test-*` target or CI job.

## Why it exists

`agent-skill-eval` invokes the host CLIs as bare subprocesses and passes no
isolation flags. Its `_build_env` sets only `ANTHROPIC_BASE_URL` and
`OPENAI_BASE_URL`, so a run inherits the machine's global `~/.claude/CLAUDE.md`,
its deployed output style, and every configured MCP server. It also passes
`--dangerously-skip-permissions`.

On this machine that is not a theoretical risk. The global `CLAUDE.md` is
hundreds of lines, `writing-style.md` is loaded into every session through four
adapters, and more than a dozen MCP servers are configured. Every number a run
produced would describe that configuration rather than the skill.

## Usage

```
tests/skill-eval/run agent-skill-eval run --skill ./skills/foo --evals ./evals.json
```

`run` puts `shims/` first on `PATH` and passes the real binary's location in
`SKILL_EVAL_REAL_CLAUDE`. The shim refuses to run without that variable rather
than guessing, so it can never silently exec itself.

## The flags, and why each one

| Flag | Effect |
|---|---|
| `--setting-sources project,local` | drops the user settings source, which carries the global `CLAUDE.md` and the output style. Workspace `.claude/skills` still loads. |
| `--strict-mcp-config` | no `--mcp-config` is passed, so no MCP server loads at all |
| `--settings '{"outputStyle":"default"}'` | second guard on the output style |

Auth, model selection and built-in tools are untouched, so a run still works.

`--safe-mode` is deliberately not used. It disables customizations wholesale,
including skills, which is the subject of the measurement.

`--strict-mcp-config` also blunts the sharpest edge of the
`--dangerously-skip-permissions` that `agent-skill-eval` passes: an agent running
without approvals reaches no MCP integration.

## What was verified

Four live probes, each with its opposite as the control.

| Probe | Result |
|---|---|
| Global `CLAUDE.md` visible without the flags | yes |
| Global `CLAUDE.md` visible with the flags | no |
| Workspace `.claude/skills` fires under the flags | yes, the marker skill returned its code |
| Same workspace with the skill removed | no marker, so the marker proves discovery rather than recall |

The probe asked whether the model's instructions mention a distinctive rule from
the global `CLAUDE.md`, and separately installed a one-line skill whose only job
was to return a fixed marker string.

No unit test covers the shim. Its behaviour is a property of a live `claude`
invocation, so any local assertion would restate the flag list this file writes.
The probes above are the evidence, and they cost API calls, which is why they are
recorded here rather than run by a gate.

## Only `claude` is shimmed

| Host | Isolation available | Status |
|---|---|---|
| Claude Code | `--setting-sources`, `--strict-mcp-config`, `--settings` | verified, shimmed |
| OpenCode | no flag beyond `--pure`, which covers external plugins only | not shimmed |
| Codex | `CODEX_HOME`, `-c key=value`, `--profile` | not shimmed, unverified |

`CODEX_HOME` and an `XDG_CONFIG_HOME` override for OpenCode might work, but both
directories also hold credentials, so isolating config would likely break auth.
Neither was tested. Start the spike on Claude Code, where the isolation is known
to hold in both directions.

## What this does not fix

`agent-skill-eval` has no pairwise judge and no A/A mode. Its LLM grader scores
one output against a rubric, so it produces a pass rate with no noise floor. Our
own A/A run on the writing-style harness drifted 7 of 11 prompts in one direction
with identical arms. Run identical arms here before trusting any delta.
