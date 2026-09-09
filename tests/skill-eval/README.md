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
tests/skill-eval/run claude -p "<task>" --allowed-tools "Skill,Bash"
tests/skill-eval/trajectory <index path printed by run>
```

`run` puts `shims/` first on `PATH`, passes the real binary's location in
`SKILL_EVAL_REAL_CLAUDE`, and points `SKILL_EVAL_TRAJECTORY_INDEX` at a
temporary file it prints. The shim refuses to run without the first variable
rather than guessing, so it can never silently exec itself.

Set `SKILL_EVAL_TRAJECTORY_INDEX` yourself to collect several invocations into
one index. Nothing is written into the checkout.

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

## What it observes

The shim pins a session id per invocation. Claude Code writes that session's
transcript under `~/.claude/projects/`, and the transcript carries the `tool_use`
blocks that the final answer does not. `tests/skill-eval/trajectory` reads them:

```
session c21493d3-...  cwd .../traj-probe
  skills fired: probe-marker
  tool calls:   2
    $ echo MARKER-7F3A

session 6ae9e537-...  cwd .../probe-without
  skills fired: none
  tool calls:   3
    $ ls -la ...
```

Two things come out of that which no off-the-shelf tool here provided: a boolean
for whether the skill fired, and the commands that actually ran.

The distinction matters. A check that greps the agent's prose for a command
passes when the answer merely mentions it and fails when the agent runs it
without saying so. Both failures were observed, see the spike result below.

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

## First real measurement, 2026-09-09

Two prompts against the project-scoped `repository-issues` skill, both arms, two
repeats, eight Claude Code sessions through the shim.

| Prompt | Arm | Skill fired | Tool calls |
|---|---|---|---|
| count open issues | with skill | `repository-issues`, both repeats | 3, 3 |
| count open issues | without | none | 9, 8 |
| record a new issue | with skill | `repository-issues`, both repeats | 9, 12 |
| record a new issue | without | none | 13, 16 |

**The skill fired in 4 of 4 jobs where it was installed and in 0 of 4 where it
was not.** That is the boolean neither off-the-shelf tool could produce.

**It cut tool calls in every pair**, by about two thirds on the query and about a
quarter on the creation task. Four pairs all pointing one way is p = 0.125 under
a fair coin, so the count alone does not separate from chance.

What raises it above a bare count is that the trajectory shows the mechanism.
Without the skill the agent spends its first calls discovering the command line:

```
$ wc -l scripts/issues && head -80 scripts/issues
$ python3 scripts/issues --help
$ python3 scripts/issues create --help
```

With the skill it goes straight to the answer:

```
$ python3 scripts/issues list --status open --json
```

No A/A run was taken here, so there is no noise floor for the call counts. The
firing boolean needs none: 4 against 0 with a known cause.

This also corrects the earlier spike, which reported that the arm with the skill
had not used the command line. That came from the prose grep described below.
Observed properly, the arm with the skill used it in every job.

## Noise floor, identical arms

The same eight jobs with the skill installed in **both** arms, so every
difference is noise by construction.

| Prompt | Arm a | Arm b | Spread with nothing changed |
|---|---|---|---|
| count open issues | 3.0 | 3.0 | 0.0 |
| record a new issue | 10.5 | 13.0 | 2.5 |

Against the measured effect:

| Prompt | With skill | Without | Effect | Floor | Effect over floor |
|---|---|---|---|---|---|
| count open issues | 3.0 | 8.5 | 5.5 | 0.0 | clears it outright |
| record a new issue | 10.5 | 14.5 | 4.0 | 2.5 | 1.6x, not separated |

**The two tasks answer differently, and only the floor makes that visible.** On
the query the skill removes discovery entirely and the count is perfectly stable
across identical arms, so a gap of 5.5 calls is the skill. On the creation task
the agent explores regardless, one identical-arm run spent 15 calls against 10
and 11 for its siblings, and a gap of 4.0 against a floor of 2.5 proves nothing.

Reporting the earlier "cut tool calls in every pair" without this would have
sold a real result and an unproven one as the same finding.

The firing boolean needs no floor and now stands at 12 of 12 jobs with the skill
installed and 0 of 4 without.

Two prompts and two repeats is a small sample. The floor is what a third prompt
would have to clear, not a claim that these two generalise.

## Why `agent-skill-eval` is not used

It was installed, run, and dropped. The eval suite written for it is deleted; the
result below is what remains, because the finding is the value.

## Spike result, 2026-09-09

One run of two eval cases against the project-scoped `repository-issues` skill,
one repeat, both arms, through the shim. Four Claude Code sessions, $1.75, exit 0.

**The pipeline works.** Install from PyPI, fixture copying, a fresh git workspace
per arm, skill installation into `.claude/skills`, real `claude` subprocesses
through the shim, deterministic grading, no grader API key. The tool reported
"All 7 assertion(s) match deterministic patterns" before starting, so nothing was
silently skipped.

**Two of the three assertion types were unusable as written, and the reported
delta of +0.04 pass rate means nothing.**

`file_unchanged` failed in all four cells with `Uncommitted change detected: ??
scripts/issues`. Fixtures are copied after the workspace's initial commit, so
they are untracked and the assertion fails whatever the agent does. Fixed here
with `stage_files: true`.

`command_ran` is a grep over the agent's text, not an inspection of its tool
calls. In the create case it passed on this sentence from the answer:

> `...isn't present in this workspace, which only carries `scripts/issues`.`

No command had to run. The assertion also produces false negatives, because a
command the agent does not echo never appears. The recorded logs hold the final
answer and a small JSON result, not a trajectory of Bash invocations. Both
`command_ran` and `command_not_ran` are dropped from this suite.

This explains the audit finding that the tool has no "the skill fired" boolean
and its README tells you to eyeball the evidence: the data needed for that check
is not captured. It is captured in the session transcript, which is what
`trajectory` reads and what made the tool unnecessary here.

**What the skill actually did**, read by hand from the outputs rather than from
any assertion:

- Create, with the skill: created `docs/issues/2026-09-09-001-...md`, ran
  `validate` on the full corpus, and caught that the prompt's requested type
  `feature` is not in the schema, choosing `idea` and naming the alternative. The
  prompt was wrong and the skill was right.
- Query, with the skill: correct count and ids, and it distinguished `status:
  open` from the CLI's default active view.
- Query, without the skill: also correct.

**What remains testable here.** State assertions on the workspace, once fixtures
are staged: a file must exist, must contain something, must be unchanged. Which
command produced the state is not reliably observable, so "did the agent use the
CLI rather than hand-writing the file" cannot be asserted with this tool as it
stands.
