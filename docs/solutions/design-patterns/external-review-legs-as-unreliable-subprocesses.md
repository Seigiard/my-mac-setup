---
title: External review legs as unreliable subprocesses
date: 2026-08-14
last_updated: 2026-08-23
category: design-patterns
module: agent-platform
problem_type: design_pattern
component: development_workflow
severity: high
resolution_type: workflow_improvement
related_components:
  - tooling
applies_when:
  - "Dispatching independent claude/opencode review legs from a durable pipeline stage"
  - "Classifying an external leg's outcome from its report file or free-text status"
  - "Choosing timeouts for headless agent-CLI invocations that background themselves"
  - "Deciding whether a missing or malformed leg report counts as failed or as zero findings"
  - "Adding liveness detection (idle timeout) around a long-running external subprocess"
symptoms:
  - "A review leg that died quietly was read as zero findings, so the gate passed with no review coverage"
  - "Agent CLI harness behavior (backgrounding, headless wait limits) silently truncated legs before completion"
  - "A fail-closed success allowlist over free-text status discarded a healthy leg and dropped its findings from the merged report"
tags:
  - external-llm
  - se-pipeline
  - smithers
  - fail-closed
  - liveness
  - timeout
  - subprocess-contract
  - status-classification
---

# External review legs as unreliable subprocesses

## Context

> **Where this evidence lives now.** The Smithers runtime and both `se-pipeline` executors were
> removed on 2026-09-01 (`docs/decisions/0001-se-pipeline-architecture-redirection.md`), so every
> `dot_smithers/**` path cited below is readable only in git history. The leg contract was re-implemented in prose rather than abandoned: `home/private_dot_claude/shared/herdr-peer-launch.md` carries the report-file transport, the symlink refusal and the degrade ladder. See **Successor gap** below for the one rule that did not survive.

The se-pipeline dispatches **external legs** — a single review pass executed by a separate, headless agent CLI process (claude or opencode) that returns a report and nothing else — whose JSON reports are merged deterministically before a gate counts P0/P1 findings. Each leg is a subprocess running a full multi-persona review inside another agent harness, and the pipeline has accumulated hard-won rules about how such legs die: silently, partially, or while wearing a valid-looking report.

The original incidents (session history, 2026-07-24): two dead `review-claude` legs in one day, with different causes. The smithers run with id prefix 9925bb0d hung — log heartbeats showed `(0 bytes)` from ~minute 35 while the CLI burned the entire 45-minute wall-clock cap; the run with id prefix 89938dd6 emitted garbage instead of a valid envelope (`AGENT_CLI_ERROR`). Both runs "succeeded" with the review riding on the surviving opencode leg alone. `retries: 0` on review legs is deliberate (a prior budget incident: 4 attempts × ~$15 on one diff), which makes any false-positive kill an unrecoverable loss of a live review. The stall fix is the origin plan `docs/plans/2026-07-24-003-fix-review-leg-stall-and-unwrap-plan.md` (status: done).

The defining later incident (fix commit `2c4f533`, 2026-08-12): twice in one day the claude review leg dispatched its persona subagents and returned **without synthesis** — once as an empty report with status `waiting_for_reviewers`, once with status `failed` — and both counted as a healthy leg with zero findings. Root cause was a harness behavior change: claude CLI >= 2.1.198 backgrounds Task subagents by default, and a headless `-p` session waits for background subagents at most 10 minutes, so the leg hit the ceiling and died before synthesis; the engine's JSON salvage cascade then captured an in-flight object that satisfied the pass-through schema (`home/private_dot_claude/dot_smithers/workflows/lib/agents.ts:135-141`).

## Guidance

**1. Default-dead: absence of a well-formed report is a leg failure, never zero findings.**
The dangerous default is counting a dead leg as "no findings" — a green report that reviewed nothing. Every layer here encodes the inversion:

- `home/private_dot_claude/dot_smithers/workflows/lib/reviewer.ts:4-6` — "Dead-leg detection is the key rule — a block that ended non-terminal (idle-killed, crashed) is failure evidence, never a silent zero-findings clean pass." Concretely, `reviewer.ts:12,35` puts `"non-terminal"` in `FAILURE_STATUSES` alongside `"failed"`.
- `home/private_dot_claude/dot_smithers/workflows/lib/review-merge.ts:22-37` (`parseLeg`) — a report with a valid shape but a status that claims failure or an unfinished state is "a dead leg wearing a valid shape — its findings are partial at best" and maps to `{ ok: false, findings: [] }`. The same comment draws the boundary that guidance 5 below explains: a status the vocabulary simply does not recognise is *not* that case.
- `home/private_dot_claude/dot_smithers/workflows/lib/review-schema.ts:26-48` — every status predicate is word-boundary containment, not exact match, because real statuses vary in both directions ("SMOKE OK", "reviewers complete", "completed: <list>" are healthy; `waiting_for_reviewers` is not):

  ```ts
  const TERMINAL_REVIEW_STATUS = /\b(complete|completed|done|ok|success|succeeded)\b/i;
  ```

  Containment cuts both ways, so negation is checked in both directions too (`review-schema.ts:44,48`): "not completed" is a failure that plain containment would pass, and "no errors" is health that plain containment would fail. Separators are normalised to spaces first, because underscores are word characters — `\bwaiting\b` does not match `waiting_for_reviewers`, the exact status this vocabulary exists to catch.

The same family, one layer up (session history): a schema-valid severity summary saying `maxSeverity: "P0"` with `p0Count: 0` originally passed the gate green — the gate read only the count. The fix is cross-field validation in `home/private_dot_claude/dot_smithers/workflows/lib/severity-summary.ts`: a contradictory summary is malformed and degrades to advisory. Layering principle: leg **availability** stays fail-closed; the severity layer degrades to advisory, never to silent green. That layering — and the protected-slot rule governing how the severity line is extracted from the envelope at all — is developed in full in `protected-slot-signal-extraction.md`.

**2. The harness is part of the dispatch contract — pin its execution-mode env vars.**
`agents.ts:142`:

```ts
const DISABLE_BACKGROUND_TASKS_ENV = { CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: "1" };
```

The surrounding comment (`agents.ts:128-141`) records two layers: a system-prompt rule telling the leg to dispatch personas as blocking parallel calls (backgrounded subagent state is not durable across turns — one run re-dispatched a reviewer and doubled wall time), and the env var as the hard layer under it, because the CLI has no flag to disable background execution and version 2.1.198 changed the default underneath the pipeline. Version-sensitive harness behavior is a dependency; pin it explicitly (`env:` on every claude review agent, `agents.ts:156,182`). Commit attribution: `git log -S CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` returns only `2c4f533` — the env pin and the terminal-status check landed together as the two layers of one fix. Prose-only instructions were measurably insufficient on their own (session history): despite the dispatch rule, 45 of 66 measured leg sessions still had over a minute of dispatch spread until the rule was made structural — the complete persona set decided first, all subagent calls in one message (`home/private_dot_claude/dot_smithers/workflows/lib/consult-prompt.ts`, with a test). The general form of that observation — prose loses to whatever concrete thing sits beside it in the same prompt — has its own incident and remedy in `docs/solutions/design-patterns/absolute-paths-beat-prose-in-agent-isolation.md`.

**3. Give legs liveness detection AND generous wall-clock — they are different budgets.**
`agents.ts:15-24`: `idleTimeoutMs` is the spawn layer's `PROCESS_IDLE_TIMEOUT`, reset on every stdout/stderr byte, so a silent leg dies at the idle threshold instead of burning the full `timeoutMs`. Values (`agents.ts:49-92`): 15 min idle for claude review profiles, 10 min for opencode, each strictly under its `timeoutMs`. The wall-clock side moved the other direction: commit `42329df` raised the opencode `timeoutMs` from 15 to 25 minutes after the tight cap killed a healthy still-streaming attempt one second before its last event, while the 10-min idle threshold still catches genuine stalls. Two calibration lessons (session history):

- Derive idle thresholds from the observed inter-chunk silence of **healthy** runs, not from the single pathological sample — healthy legs legitimately go silent (rate-limit backoff, one long tool call), and under `retries: 0` a false idle-kill is unrecoverable. The plan (KTD-B) marks the current values provisional for exactly this reason. The reliable stall signature is sustained `(0 bytes)` heartbeats, not duration: an 18-minute leg with continuous non-zero heartbeats is a normal completion (median healthy doc-review: 13.7 min, p75 23.7, max 80.8).
- Callers waiting on a leg must pad for the engine's reap lag (~13 min observed beyond the cap) — a wait-cap equal to the timeout will fire early.

The `work` profile deliberately has no idle timeout — long locally-silent commands (installs, test suites) are legitimate there.

> **Successor gap — this rule has no implementation today.** The peer launch that replaced the
> Smithers legs waits with a single flat wall clock: `herdr agent wait "$PANE" --timeout 1800000`
> (`home/private_dot_claude/shared/herdr-peer-launch.md:119-120`), 30 minutes, with no idle-timeout
> equivalent anywhere. Against the healthy-leg distribution measured above (median 13.7 min, p75
> 23.7, max 80.8), a flat 30-minute cap does both things this rule exists to prevent: it kills
> healthy long legs, and it lets a silent one burn the entire budget instead of dying at an idle
> threshold. The guidance stands; the successor does not implement it.

**4. Validate reports at the boundary; fail closed on missing/unparseable — and salvage before schema validation.**
`review-merge.ts:22-37` (`parseLeg`): missing raw → failed; JSON parse error → failed (never throws); no `findings` array → failed; a status that claims failure or an unfinished state → failed. The gate turns all-legs-failed into `degraded` and one failed leg into an advisory reason. Two sub-rules:

- Declare the fields you consume in the schema (`review-schema.ts:11-18`) — smithers persists only schema-declared fields, so an undeclared `findings` array is silently dropped in capture and every leg then parses as failed.
- Salvage/unwrap lives at capture/extraction, **before** Zod validation (session history): an invalid envelope reaching Zod triggers a silent full agent restart within the same attempt. `parseLeg` is the reference pattern — never throw, fail closed.

**5. Fail closed on absence of evidence, not on an unfamiliar adjective.**
Fail-closed has a price when it is applied to a model's free text, and the price was measured: on the identical `fixture-reverse-plan` fixture, run-1786539437958 (status `completed`) went green while run-1786700241899 (status `findings`) had its healthy leg discarded, its well-formed P3 finding dropped from the merged report, and the run parked for a needless approval — the exact interruption cost the pipeline exists to remove. The second-order cost is worse than the pause: a real P0 from a leg that said `findings` would have vanished from the merged report while the run degraded for an apparently unrelated reason.

The resolution (`2026-08-14-002`, status: done, fix commit `186b6a8`) inverted the rule rather than widening the word list: **health is judged by the payload, not by the adjective.** `isUsableReviewLegStatus` (`review-schema.ts:62-71`) replaced the success allowlist at the merge call site, and asks in order — a missing, non-string, or empty status fails the leg (this is where the fail-closed intent survives: no evidence is not health); a negated success word ("not completed") fails; a known success word passes; an explicit failure or progress state fails; and **anything else passes**, because the caller has already required a parsed `findings` array, and that array is the evidence the leg ran. Replayed against the recorded run, the discarded leg comes back with its P3 finding and the run no longer parks.

Two rejected alternatives are worth keeping visible. Widening the allowlist was the cheapest change and the least durable — the next unseen synonym reintroduces the identical failure. Constraining the status to an enum the model cannot paraphrase is genuinely better *where it reaches*: the claude leg already takes `reviewLegJsonSchema` (`review-schema.ts:77-83`), but the opencode path could not be shown to carry the same constraint, and a rule covering one leg of two is not a rule. Prefer the schema constraint when every leg can take it; fall back to payload evidence when they cannot.

The doc-review exposure suspected alongside this turned out not to exist: `docReviewGate` reads statuses computed in code (`se-doc-review.tsx:189` — `claudeStatus: claudeReview ? "ok" : "failed"`), so no model-chosen word reaches it. Worth checking deliberately rather than assuming — the same vocabulary appearing at two gates does not mean a model feeds both.

## Why This Matters

A review leg that dies quietly and reads as "zero findings" defeats the entire purpose of the review stage: the gate passes on evidence that was never produced. The `2c4f533` incident shows this is not hypothetical — a harness version bump made every claude review leg structurally incapable of finishing synthesis, and for a while the pipeline reported those deaths as clean passes. The two-leg architecture is worth defending against dead legs (session history): a semantic comparison of 52 leg pairs found exact parity in substantive unique findings (92 claude vs 92 opencode, 144 shared clusters), and three runs had opencode raising P1s where claude reported clean — losing a leg loses real signal, not redundancy. Fail-closed status validation converts silent false-greens into visible pauses. But the allowlist incident showed that fail-closed applied to a model's free-text adjective has its own measured cost: false-failed healthy legs, dropped findings, and needless human interruptions. Both failure modes are real, so the rule has to be placed rather than dialled: schema-constrained enums at the boundary, payload-based health where the payload is decisive, and fail-closed only where the report is genuinely missing or unparseable. That is now the shipped position, not an aspiration.

## When to Apply

- Dispatching any external LLM/agent CLI as a subprocess whose output feeds a gate, merge, or automated decision.
- Designing the report contract for a review/verification leg: status fields, findings arrays, output schemas.
- Upgrading the agent CLI a pipeline spawns — check for execution-mode default changes (backgrounding, wait ceilings) and pin them via env.
- Setting timeouts for a subprocess that streams: separate idle (liveness) from wall-clock (budget); a stalled leg must die by idle timeout, not hang the stage or burn the full cap.
- Tempted to classify a model's prose ("completed", "findings", "done reviewing") — reach for a constrained enum or payload evidence instead.

## Examples

- Dead leg wearing a valid shape: status `waiting_for_reviewers` with an empty findings array, salvaged from a session killed at the 10-min background-wait ceiling — rejected by `parseLeg` (`review-merge.ts:32`), fix commit `2c4f533`. Still rejected after the payload-health inversion, and covered by a test that says so.
- Harness pin: `agents.ts:142` `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS: "1"` applied to every spawned claude review/apply agent (`agents.ts:156,182`), layered under the synchronous-dispatch system prompt (`agents.ts:144-145`).
- Liveness vs wall-clock: opencode profile `timeoutMs: 25 * 60_000`, `idleTimeoutMs: 10 * 60_000` (`agents.ts:87-92`) — raised cap after killing a healthy streaming leg (commit `42329df`), kept idle threshold for genuine stalls.
- Measured fail-closed cost, then the inversion: two runs on one fixture, `completed` → green vs `findings` → leg discarded and run parked; fixed by judging the payload (`2026-08-14-002`, done; commit `186b6a8`). The fix was verified by replaying the recorded run's legs out of `smithers.db` through the merge, before and after — 0 merged findings and a pause became 1 merged finding and no pause. A unit test alone would not have shown that the finding had been disappearing.
- Leg-death forensics entry points (session history): the run's `stream.ndjson` heartbeat log under the smithers executions directory, `_smithers_attempts.response_text` in `smithers.db`, and the leg's own session JSONL.

## Related

- `2026-08-14-002` — the false-fail bug: measured cost of fail-closed on free text, the three candidate directions, and why payload-based health won (status: done, commit `186b6a8`).
- `docs/plans/2026-07-24-003-fix-review-leg-stall-and-unwrap-plan.md` — the original stall/unwrap fix (status: done).
- `home/private_dot_claude/shared/herdr-peer-launch.md` — the successor contract: report-file transport,
  symlink refusal, "a settled state is only a wake-up signal", and the degrade ladder its callers
  (`se-code-review`, `se-doc-review`, `se-simplify`) restate. It replaced `docs/se-pipeline.md`, which
  was removed with the Smithers runtime.
- `docs/solutions/design-patterns/protected-slot-signal-extraction.md` — the full development of the severity-layer paragraph above: protected-slot extraction (decoys inert by position), cross-field consistency, and why the additive layer may fail open to advisory while leg availability stays fail-closed.
- `docs/solutions/design-patterns/completion-is-not-a-verdict.md` — sibling pattern one layer later: here a dead leg misled the *machine*, there a failed gate misled the *human* reading the log. Same false-green family, different reader.
- `docs/solutions/design-patterns/idle-machine-wall-clock-bounds-are-latent-flakes.md` — sibling test-harness pattern: prefer causal assertions, or separate a generous hang guard from the narrow behavioral assertion when elapsed time is unavoidable.
- `docs/solutions/architecture-patterns/pre-external-secret-boundary-for-coding-agent-pipelines.md` — sibling pattern sharing the fail-closed principle at a different boundary (a scanner crash is never a clean pass).
- Closed issues above are bare IDs, for archaeology in git history: `2026-08-14-002`. The file was
  removed in the closed-issue cleanup; the evidence it carried is reproduced inline above.
