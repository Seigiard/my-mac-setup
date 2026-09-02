---
title: se-pipeline architecture redirection
status: rejected
date: 2026-08-15
supersedes: []
---

# ADR-0001: se-pipeline architecture redirection

## Status

**Rejected.** The Smithers runtime and both executors were removed on 2026-09-01.
This document remains as the historical analysis that preceded that decision.

## Context

`se-pipeline` was a durable execution system for long-running coding agents, built on
Smithers. It lived in `home/private_dot_claude/dot_smithers/` and was driven by the `se`
CLI and a set of `se-*` skills. Two executors existed side by side: `se-pipeline.tsx`
(1100 lines, a fixed four-stage conveyor) and `se-flow.tsx` (940 lines, a generic
interpreter that executes a declarative flow spec composed from a library of typed
blocks).

The original goal of the composable layer was a *dynamic flow*: assemble the flow a task
needs out of reusable blocks, keep blocks compatible with each other, and keep planning
documents independent of execution. An audit of the shipped code against those three
goals found that two of them are not met, and that a fourth structural cost was paid for
capability that is not used.

### Finding 1 — block compatibility checking is a tautology

Every block in the library declares the same two schema identities,
`flow.handoff.in` and `flow.handoff.out` (`workflows/lib/blocks/index.ts:34-35`), and the
registry declares one self-adapter between them (`workflows/lib/blocks/index.ts:412`).
The compatibility check at `workflows/lib/flow-validate.ts:148` compares those identities,
so for the shipped library it can never fail.

The check that would catch real errors is absent: the validator never parses a block's
declared `input` against that block's own Zod schema. A spec carrying a malformed input
passes validation and fails later, at dispatch.

### Finding 2 — the graph carries no data, only order

No block reads another block's output into its own input. The `bindTo` edge is a
staleness binding: it withholds a block until the upstream row exists and parks the run
if that row later changes (`workflows/lib/flow-run.ts:307-317`). Most blocks declare
`inputSchema: z.object({})`. Real values reach a block from ambient run state — the
staged worktree, `run.baseSha`, `run.validateCmd`.

The composition model is therefore *effects over a shared worktree in topological
order*, which is a sound model. It is described and validated as if it were a dataflow
graph of typed ports, which is the mismatch that makes the layer expensive.

### Finding 3 — the plan is execution configuration, read by heuristics

`workflows/lib/plan.ts` is 469 lines of shell lexing and runner classification whose
job is to recover a verification command from a planning document written in markdown.
It reads either a `validate_commands:` list in the plan's YAML frontmatter or a
`Verification Contract` prose section, parsing backticked commands out of tables, fenced
blocks and list items. `workflows/lib/gates.ts:89-98` additionally requires the frontmatter
keys `artifact_readiness: implementation-ready` and `execution: code`.

The plan therefore carries an implicit, unversioned schema that is documented nowhere as
a single contract. Its parts are spread across an external plugin's plan template, the
comments in `plan.ts`, prose in `skills/se-work/SKILL.md`, and the text of the launch
refusal.

The trust argument in the code is inverted. `workflows/lib/plan.ts:1-5` states that the
plan is a trusted operator-authored input while a command read from the target
repository's own configuration is forbidden. In practice the plan is written by an agent
and the derived command is printed to stderr only after launch
(`workflows/se-pipeline.tsx:496`), so no human inspects the criterion before it is used.
The repository's committed configuration has a third author and is under version
control.

### Finding 4 — the baseline is captured and then discarded

A probe runs the verification command once on the base commit before any paid work and
classifies the result (`workflows/se-pipeline.tsx:579-602`), distinguishing a missing
runner and a broken environment from a genuine assertion failure. The result is logged
and never read again. The work gate requires a bare exit code of zero
(`workflows/lib/gates.ts:316-319`).

Two consequences follow. A repository that is red at base can never pass the gate. A test
that already failed before the work started is charged to the work.

### Related costs

- **Two executors, one semantics.** Gate behavior exists twice; commit `89ed25a`
  ("Close the same two doors in se-flow's work block") is one fix applied twice.
- **Composition never varies.** `skills/se-flow/SKILL.md` gives three fixed block chains
  in prose, one per task classification. The composition engine exists to emit them.
- **Provisioning knowledge is hand-carried.** A staged worktree is a bare checkout, so the
  operator retypes install and build commands into `--setup-cmd`; the failure messages at
  `workflows/lib/gates.ts:157-160` exist entirely to ask for it. The repository already
  describes how to build itself.
- **Multi-agent review does not need an engine.** `skills/pf-spec/SKILL.md` step 4 sends a
  spec to a second model for review with one `opencode run` invocation inside an ordinary
  session. `workflows/se-doc-review.tsx` does the same job as a 217-line Smithers workflow.
- **A scheduler is already reimplemented in prose.** `skills/pf-build/SKILL.md` carries a
  PR watcher, a mandatory `/loop 30m` heartbeat, a stuck-detection checklist, and the rule
  to re-derive the task list from disk rather than from memory. Those instructions exist
  because a chat session forgets and dies. That is the problem a durable engine solves.

## Requirements

The redirection must serve these, gathered from the repo owner:

1. **One entry.** An idea, a plan, or a plain task description is a valid input.
2. **Planning exhausts the decision surface.** Brainstorm, requirements, a vision presented
   for confirmation, blocking open questions, document review, then approval. A question
   that surfaces after approval is a planning defect, not normal operation.
3. **A "before" artifact is optional and self-selected.** The flow decides what, if
   anything, is worth capturing as the prior state; for some tasks there is nothing.
4. **Autonomy after approval.** Slicing into tasks, sub-agents, per-task code review and
   simplification, merge into the task branch, final check, "after" artifact, pull request.
5. **Waking the human is rare and earned** (see Decision 4).
6. **A red gate is repaired before a human is involved**, not after.
7. **Plans are independent of execution.**

## Decision 1 — The steps are agent knowledge, not a system

A single skill, `se-investigate`, is the entry point. It knows which steps exist and which
steps each kind of task usually wants. It investigates with the human what they actually
want, then runs the steps the work needs, in the order the work needs, deciding the next
one after seeing the last one's result.

Typical sequences, as knowledge the skill carries rather than artifacts anything produces
or validates:

```
brainstorm → plan → doc-review → work → code-review → simplify → PR
debug → reproduce → fix → code-review → simplify → verify → PR
brainstorm → plan → doc-review → artifact-before → work → code-review → simplify
  → artifact-after → record-proof → PR
```

Delete everything built to describe and check a composed flow: the flow spec schema, the
pre-launch spec validator, the schema-identity and adapter system, the `after` / `bindTo`
edge model, cycle detection, and ancestor-closure checks. Nothing composes a spec, so there
is no spec to validate.

**What stays code, and why.** Only what is expensive when forgotten and invisible in the
moment:

- **A secret scan before run content leaves the machine.** An agent that forgets this leaks,
  and nothing in the moment shows it.
- **Explicit retries and timeout on every unattended leg.** The engine's own default is to
  retry forever.
- **The verification comparison** (Decision 3).

Everything else — which step follows which, when a reproduction is needed, whether proof
artifacts are worth capturing — is judgement the skill states in prose, because the agent
making the call holds more context than any pre-flight check would.

**Rejected alternative — repair the type system.** Give each block a real input and output
schema identity and check inputs against their Zod schemas at compose time. Rejected: no
block reads another block's output as its input, so there are no dataflow edges to
typecheck.

**Rejected alternative — a fixed recipe per task type.** Rejected: it reintroduces the three
hard-coded chains, and the sequences above differ in ways a classifier cannot anticipate.

**Consequences.** Positive: roughly two thousand lines of registry, spec, and validator
disappear, and the flow becomes readable prose in one skill. Negative: correctness of
ordering now rests on the skill being well written and on the agent following it, with only
the three guards above as a hard floor.

## Decision 2 — Where a step runs is a per-step choice, and Smithers is one option

The agent picks the venue for each step as it goes. Four are available:

- **Itself, in the session** — dialogue and anything short. `brainstorm`, `plan`.
- **A subagent** — bounded work with its own context that returns a result.
- **Smithers** — a step that must survive the session: hours unattended, resumable after
  process death, with a durable record of what it produced and cost.
- **A herdr pane** — an agent running beside the human, visible, steerable, outliving the
  session without an engine.

Smithers is therefore one execution option among four, never the orchestrator of the flow
and never the mechanism for dialogue with the human. Nothing in the design requires a step
to use it; the choice is made per step, at the time, by the agent that knows what the step
costs.

The human appears once in the middle. When planning is done and `doc-review` comes back with
no open questions, the agent reports "the plan is ready, no open questions" and starts the
autonomous part. Everything after that is Decision 4.

**Rationale.** A durable engine buys resume-after-death, a durable cost and output record,
and survival past the session. Those are properties some steps need and most do not. Making
the engine the runtime of the whole flow pays for them everywhere, including in the dialogue,
where routing through a pause mechanism produces exactly the opaque hand-off this
redirection exists to remove.

**Rejected alternative — one durable run from idea to pull request.** Rejected: it forces the
planning dialogue through the pause mechanism.

**Rejected alternative — no engine at all, chained skills only, as in the `pf-*` cycle.**
Rejected: `pf-build` demonstrates the cost, having grown a PR watcher, a heartbeat loop, and
stuck-detection rules to compensate for a session that forgets and dies.

**Consequences.** Positive: each step pays only for the durability it needs, and the long
unattended legs keep a real engine under them. Negative: four venues mean four failure modes
and four ways to read progress, and the skill has to say plainly which venue suits which
step or the choice becomes arbitrary.

## Decision 3 — The verification contract comes from the repository

The plan stops carrying execution configuration. Delete `workflows/lib/plan.ts`, the
`validate_commands:` frontmatter key, the `Verification Contract` parser, and the launch
refusal that fires when neither is present.

Replace with two steps in the autonomous tail:

- **verify-setup**, on the base commit, before any work: discover the setup and test
  commands from the repository's own committed configuration, pin them together with the
  base commit SHA, provision, run them, and record a baseline snapshot of what passes and
  what fails. A red baseline is recorded, not fatal.
- **validate**, at the end: re-run the pinned commands and compare against the baseline
  snapshot. Green turning red is a regression. Expected-red turning green is the work
  landing. The comparison, not a bare exit code, is the verdict.

An operator flag remains as an override for the case where a full run is too slow and must
be narrowed.

**Rationale.** Discovery reads the repository at the base commit, before any agent has
touched it, and pins the result — so the party being checked cannot author its own check.
This is strictly stronger than trusting a command parsed out of an agent-written document,
and it removes the need for the operator to retype provisioning commands the repository
already documents.

**Rejected alternative — keep the plan as the source but make its schema explicit and
versioned.** Rejected: the plan is authored by an agent, so the criterion is not
independent of the work; making the schema explicit fixes the discoverability complaint
but not the trust inversion.

**Rejected alternative — replace the deterministic check with a model asked to confirm the
work.** Rejected as a *replacement*: a model that judges its own kind of output after
seeing it is another self-report. Retained as an addition, because a model's finding is
worth much more when it fails a run than when it passes one; that role is already filled
by code review.

**Consequences.** Positive: 469 lines of heuristics deleted, a whole class of launch
refusals disappears, and a repository that is red at base becomes runnable. Negative:
discovery must handle repositories whose test command is not machine-discoverable, and it
must decide what to do when the repository offers several plausible commands.

## Decision 4 — Autonomy after approval, with a three-condition wake test

After approval the run is autonomous. It wakes the human only when **all three** conditions
hold:

1. the choice changes what the product observably does;
2. the answer is not present in the plan, the repository, or the task; and
3. the mistake is expensive to reverse — a migration, a breaking change, or something
   already published outside the run.

Everything else the run decides itself and records as an assumption in its final report.

A red gate is repaired before a human is considered: the failing step receives the error
text and retries. Only a failure that survives repair is eligible for the wake test.

When the run does wake the human, the message is self-contained: what happened, what is
being decided, the options with their consequences, and a recommendation. A log tail is
not a message.

**Rationale.** Two failure modes are being designed out. Parking on a trivial, mechanically
repairable failure with an output that does not say what happened. Being asked fifty
consecutive questions whose answers change nothing observable.

**Consequences.** Positive: the human is interrupted only where interruption is worth its
cost. Negative: a wrong autonomous call now surfaces at the pull request rather than at the
moment it is made, which raises the burden on the assumption log in the final report.

## Decision 5 — State lives in files, and the plan is orchestrator-private

The orchestrating agent keeps its steps in a file and marks them done as it goes, in the
style of `pf-build`'s `tasks/` directory. That file, re-read from disk rather than
remembered, is how a dead session resumes — the durability property, obtained without an
engine.

Three rules make the file trustworthy rather than a source of confident lies:

- **Split the ownership of status.** The file is authoritative for what remains to be done.
  For a step dispatched to another venue, the file holds that step's run identifier and
  nothing more; what the step produced is told by the executor's own record. Nothing can
  drift, because nothing is stated twice.
- **The plan never leaves the orchestrator.** A dispatched step receives a self-contained
  brief — what to do, what counts as done, the context to do it — never a path to the plan
  and never the neighbouring steps. `workflows/lib/blocks/index.ts` currently hands the work
  agent a plan path, and run `run-1786717826270` is what that cost: the agent resolved
  repository paths against the plan's own repository and wrote its work into the operator's
  checkout. The guard against it today is a paragraph of prose in the prompt. A brief
  removes the failure mode instead of warning about it.
- **A threshold.** Below some size a task gets no tracker at all, as `pf-build` provides
  through `references/direct-build.md`.

**Rationale.** A brief is text, so the same step runs unchanged in a subagent, in a headless
CLI session, or in a herdr pane — which is what makes Decision 2's four venues
interchangeable. A plan path only works when the recipient shares the orchestrator's
filesystem and assumptions.

**Consequences.** Positive: recovery without an engine, state the human can read and correct
mid-flight, and one class of workspace-confusion bugs removed by construction. Negative: the
file is an unenforced convention — `pf-build` carries scar tissue for this ("flip the status
as you go, never batched", "never a remembered list", plus a heartbeat that re-checks), and a
file the agent forgets to update is worse than no file. Translating the plan into briefs is
real work, and the quality of the whole run now lives in that translation.

## Not decided here

- **The unit of task slicing.** Whether each sliced task gets its own branch and pull
  request merged into a task branch, as in `pf-build`, or whether the tail works on one
  branch.
- **Which venue suits which step.** The four options in Decision 2 need a plain statement of
  when each one is right, or the choice is arbitrary in practice.
- **Migration order.** Which of `se-pipeline.tsx` and `se-flow.tsx` survives as the tail
  executor, and what happens to runs in flight.
- **Discovery rules for verify-setup.** The precedence order among CI configuration,
  `Makefile`, package scripts, and task runners, and the behavior when discovery is
  ambiguous.

## Evidence

| Claim | Where |
|---|---|
| All blocks share one schema identity pair | `home/private_dot_claude/dot_smithers/workflows/lib/blocks/index.ts:34-35` |
| One self-adapter makes every edge compatible | `.../workflows/lib/blocks/index.ts:412` |
| The compatibility check that can never fail | `.../workflows/lib/flow-validate.ts:148` |
| `bindTo` binds staleness, not data | `.../workflows/lib/flow-run.ts:307-317` |
| Plan trusted, repository configuration forbidden | `.../workflows/lib/plan.ts:1-5` |
| Plan frontmatter required by the gate | `.../workflows/lib/gates.ts:89-98` |
| Derived command printed only after launch | `.../workflows/se-pipeline.tsx:496` |
| Baseline captured and classified | `.../workflows/se-pipeline.tsx:579-602` |
| Work gate requires a bare exit code of zero | `.../workflows/lib/gates.ts:316-319` |
| Provisioning pushed onto the operator | `.../workflows/lib/gates.ts:157-160` |
| Second-model review with one subprocess call | `home/private_dot_claude/skills/pf-spec/SKILL.md` step 4 |
| The same job as a Smithers workflow | `.../dot_smithers/workflows/se-doc-review.tsx` |
| A scheduler reimplemented in prose | `home/private_dot_claude/skills/pf-build/SKILL.md`, "Watch + heartbeat" |
| Three fixed chains the composer emits | `home/private_dot_claude/skills/se-flow/SKILL.md`, phase 2 |

## References

- `docs/se-pipeline.md` — the current runbook for the system this ADR redirects.
- `CONCEPTS.md` — shared vocabulary for the domain.
