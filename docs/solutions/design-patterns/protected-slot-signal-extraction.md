---
title: Machine signals live in one protected slot, never in a scan
date: 2026-08-21
category: design-patterns
module: se-pipeline
problem_type: design_pattern
component: development_workflow
severity: medium
related_components:
  - tooling
applies_when:
  - "Extracting a machine-readable signal (counts, verdict, JSON) from an LLM's free-text output"
  - "A gate or automated decision acts on a value embedded in prose that can quote the signal's own format"
  - "Choosing between scanning a whole envelope for a marker line and reading one designated position"
  - "Deciding how an unparseable or malformed signal should affect an additive gate layer"
  - "Echoing a machine-annotated envelope back into another agent's prompt or a human-facing synthesis"
symptoms:
  - "Review prose that quotes a decoy signal line (a literal SEVERITY example) would override the real one under a last-match or any-match scan"
  - "Stripping the machine line by prefix-matching anywhere truncated review prose that legitimately began with the prefix"
  - "A schema-valid but self-contradictory summary (maxSeverity P0 with p0Count 0) would pass the gate as green because the gate blocks on the count alone"
tags:
  - protected-slot
  - signal-extraction
  - prompt-contract
  - spoofing
  - fail-open
  - advisory-degradation
  - se-pipeline
  - smithers
---

# Machine signals live in one protected slot, never in a scan

## Context

The se-pipeline's verify-doc stage needed a blocking gate: two external review legs (claude, opencode) each produce a free-form markdown review envelope, and the pipeline must block work when a review finds a P0. The envelope stays prose by design — the only machine-readable part is a single line, `SEVERITY: {"maxSeverity":"P0|P1|P2|none","p0Count":N,"p1Count":N}`, which the leg is instructed to emit immediately before its terminal `Review complete` line (prompt contract in `home/private_dot_claude/dot_smithers/workflows/se-doc-review.tsx:133`).

The naive extraction — grep the envelope for `SEVERITY:` and take the first, last, or any regex match — is spoofable by the text itself. LLM reviews quote things: suggested edits, code fences, examples of the very format under review. During the review of this feature, envelopes literally contained decoy `SEVERITY:` lines as quoted examples. Under a last-match scan, a review that quotes `SEVERITY: {"p0Count":0,...}` *after* stating a real P0 would silently zero the real P0 and green-light the gate. The plan names this threat explicitly (KTD-B, `docs/plans/2026-07-24-002-feat-verify-doc-blocking-gate-plan.md:71`): "a position-independent last-match scan is spoofable by a later decoy line zeroing out a real P0."

The design that shipped (commits `af1a79d` work run → `33bf8f2` merge, hardened in `4b22d20` with a cross-field consistency check, P2 tails closed in `3d28f09` per `docs/issues/2026-08-14-003-severity-gate-p2-tails.md`) rejects scanning entirely.

## Guidance

**1. Read exactly one protected position; treat everything else as prose.**

The parser (`home/private_dot_claude/dot_smithers/workflows/lib/severity-summary.ts:29-47`) locates the terminal marker first, then reads the single line in the slot immediately before it — and nothing else:

```ts
export function parseSeveritySummary(envelope: string): SeveritySummary | undefined {
  const lines = envelope.split("\n");
  let terminal = lines.length;
  while (terminal > 0 && lines[terminal - 1].trim() === "") terminal--;
  if (terminal === 0 || lines[terminal - 1].trim() !== TERMINAL_LINE) return undefined;

  let slot = terminal - 1;
  while (slot > 0 && lines[slot - 1].trim() === "") slot--;
  if (slot === 0) return undefined;

  const candidate = lines[slot - 1].trim();
  if (!candidate.startsWith(SEVERITY_PREFIX)) return undefined;
  ...
```

A decoy `SEVERITY:` line anywhere in the body — in a code fence, a blockquote, review prose — is inert because the parser never looks there. A misordered trailing pair (`SEVERITY:` *after* `Review complete`) is also `undefined`: order is part of the contract, not something to repair.

**2. Layer validation on the slot's content: schema, then self-consistency.**

Position alone is not the end. The slot's JSON must parse (try/catch, never throw), counts must be non-negative integers, `maxSeverity` a known token — and the fields must agree with each other (`severity-summary.ts:53-65`): `{maxSeverity:"P0", p0Count:0}` is a plausible LLM counting slip, and since the gate blocks on `p0Count` alone, an inconsistent pair would silently pass as green. Inconsistent → `undefined` → advisory. This cross-check was the `4b22d20` hardening.

**3. Tolerance rule (KTD-D): an additive gate layer may fail OPEN — to yesterday's behavior, with visibility.**

Any parse failure returns `undefined`, degrading that leg to advisory. This deliberately diverges from the pipeline's blanket "degraded is never a silent pass" doctrine and is safe for one precise reason (plan KTD-D, `docs/plans/2026-07-24-002-feat-verify-doc-blocking-gate-plan.md:73`): the severity layer *strictly adds* blocking power on top of the pre-existing leg-availability ladder, so its absence returns the gate to exactly the prior behavior, never below it. The two layers keep distinct failure semantics in `home/private_dot_claude/dot_smithers/workflows/lib/gates.ts:103-141`: leg availability stays fail-closed (no output → `failed`, both legs down → `degraded`, `cause: "availability"`), while the severity layer takes max-of-legs on parsed summaries and fails with `cause: "severity"` only on a parsed `p0Count > 0` (`gates.ts:137-139`). The `cause` field lets the waive predicate approve past a parsed P0 while availability reds keep the extra-attempt path.

The compensating control for fail-open: per-leg parse status is surfaced every run — `docReviewSeverityStatusNote` (`home/private_dot_claude/dot_smithers/workflows/lib/doc-review-notes.ts:50`, pushed into run notes at `se-pipeline.tsx:644`) prints parsed/missing per leg, so a systemic prompt-contract failure (all legs silently missing the line) is visible, not silently inert.

**4. The signal is gate input, not content — strip it at the same position you parse it.**

`stripSeverityLine` (`severity-summary.ts:88-103`) removes the machine line before an envelope is echoed into the work prompt or a human synthesis (the interactive-skill side of the same contract: `home/private_dot_claude/skills/se-doc-review/SKILL.md:55`). The strip is position-anchored to the *same* protected slot, plus JSON-shape checked — a prefix-match-anywhere strip silently truncated review prose that legitimately began with `SEVERITY:` (prose a review has every reason to write when discussing the gate's own contract). That over-matching was P2 tail #1, fixed in `3d28f09`. The extraction rule and the removal rule must agree on where the signal lives, or one of them corrupts data.

**5. Make the wiring testable without spoofing yourself.**

Smoke runs inject `smokeSeverity` to stamp both legs' output fields directly, bypassing envelope parsing (`se-doc-review.tsx:23-25,197-208`; mirrored input at `se-pipeline.tsx:77-79`, threaded at `se-pipeline.tsx:623`) — so the gate/waive wiring is exercisable without teaching a test to fabricate a "real" SEVERITY line.

**Boundary of the pattern: protect the slot when you own the envelope contract; judge the payload when you cannot.** The cousin case (`docs/issues/2026-08-14-002-review-leg-status-allowlist-false-failures.md`, absorbed into `external-review-legs-as-unreliable-subprocesses.md` Guidance 5): a free-text status adjective could not be slot-protected across both legs, so the resolution there was payload evidence — a classifier over the findings array as independent proof, after a constrained-enum alternative was rejected as unreachable for the opencode leg — instead of a cleverer text scan.

## Why This Matters

- **The threat is not adversarial input — it is the signal channel and the content channel being the same channel.** An LLM discussing a format will quote the format. Any scan-based extractor turns those quotes into live signals; here the concrete failure was a quoted decoy silently zeroing a real P0 — the gate's one job inverted by its own extraction method.
- **A protected slot makes decoys structurally inert instead of statistically unlikely.** No regex cleverness distinguishes "the machine line" from "a quoted machine line"; position relative to the terminal marker does, deterministically. The decoy tests prove it: a code-fenced P0 decoy plus a real slot line parses the real one (`severity-summary.test.ts:79-92`); decoys in the body with prose in the slot parse to nothing (`severity-summary.test.ts:94-101`).
- **Fail-open is usually a bug; here it is a theorem with a precondition.** "Degrading to yesterday's behavior is never worse than yesterday" holds only because the layer is purely additive and only because parse status is surfaced every run. Drop either precondition and silent rot returns.

## When to Apply

Any system parsing structured signals out of model output: verdict lines, JSON result blocks, tool directives, `VERDICT:`/`APPROVED` markers, severity or score summaries. Apply when:

- The model's free text can plausibly *mention or quote* the signal format (reviews of the system itself, docs, examples, error echoes).
- You are tempted to write `text.match(/SIGNAL: .../)` or take first/last match over the whole output.
- You add a new blocking layer to an existing gate: decide explicitly whether unparseable degrades to the prior behavior (additive → allowed to fail open with surfaced status) or must fail closed (replacing a control → it must). This is the blast-radius bias principle applied to a parse-failure default (see `gate-bias-follows-blast-radius.md`).
- You both parse a signal and re-emit the surrounding text elsewhere: anchor the strip to the same position as the parse, or you will eat legitimate prose (the `3d28f09` lesson).

The same reasoning already appears in two familiar designs: terminal markers for agent output (the marker's *position* is the contract) and git commit trailers (parsed only from the last paragraph, so "Signed-off-by:" in the body is prose).

## Examples

Real decoy test — the exact scenario that motivated the design (`severity-summary.test.ts:79-92`):

```ts
test("realistic envelope: decoy SEVERITY in a code fence, real line in slot → real parsed, decoy inert", () => {
  const e = envelope([
    "## Applied fixes",
    "Suggested edit:",
    "```",
    `SEVERITY: {"maxSeverity":"P0","p0Count":9,"p1Count":9}`,
    "```",
    "> quoted prose mentioning SEVERITY: as an example",
    "",
    `SEVERITY: {"maxSeverity":"P1","p0Count":0,"p1Count":4}`,
    "Review complete",
  ]);
  expect(parseSeveritySummary(e)).toEqual({ maxSeverity: "P1", p0Count: 0, p1Count: 4 });
});
```

Per-leg parse with smoke bypass (`se-doc-review.tsx:197-203`):

```ts
const smokeSeverity = ctx.input.smoke ? ctx.input.smokeSeverity : undefined;
if (claudeReview) {
  ...
  const severity = smokeSeverity ?? parseSeveritySummary(claudeReview.envelope);
  if (severity) result.claudeSeverity = severity;
}
```

Additive-ladder gate, distinct causes (`gates.ts:109-141`): availability failures carry `cause: "availability"`; only a parsed P0 fails with `cause: "severity"`; a leg with a missing summary contributes an advisory reason (`"severity summary missing (advisory — leg-availability-only for this leg, R5)"`, `gates.ts:134`) instead of a verdict change.

## Related

- `external-review-legs-as-unreliable-subprocesses.md` — sibling pattern and the compressed prior: its Guidance 1 closing paragraph states the cross-field-validation incident and the "availability fail-closed / severity advisory" layering this doc develops; its Guidance 5 covers the cousin problem of classifying a model's free-text status adjective.
- `completion-is-not-a-verdict.md` — same false-green family, human-facing layer; its "absent reason must not read as absent problem" rule is the same instinct behind surfacing per-leg parse status every run.
- `gate-bias-follows-blast-radius.md` — the general bias-placement principle; the tolerance rule here is that principle applied to a parse-failure default instead of a run/skip default.
- `../architecture-patterns/pre-external-secret-boundary-for-coding-agent-pipelines.md` — the fail-closed counterpart: a subtractive security boundary can never fail open, which is why the additive-only condition is load-bearing in this doc's tolerance rule.
- `../../plans/2026-07-24-002-feat-verify-doc-blocking-gate-plan.md` — origin decisions KTD-B (protected slot, decoy-spoofability rationale) and KTD-D (tolerance layering + parse-status observability); the superseded requirements doc is `../../plans/2026-07-24-001-feat-verify-doc-blocking-gate-requirements.md`.
- `../../issues/2026-08-14-003-severity-gate-p2-tails.md` — done: `stripSeverityLine` converged on the same protected-slot rule the parser uses — the second, write-direction application of the slot idea.
- `../../issues/2026-08-14-008-doc-review-path-has-no-live-coverage.md` — the live-coverage run recording that the slot parse, stripped advisory, and per-leg severity read work on the green-gate path; still open because the waive-note strip path (same slot mechanism, different consumer) remains unproven live.
- `../../se-pipeline.md` — runbook carrying the operational gate semantics (P0 blocks, P1 advisory, missing severity degrades to advisory).
- Commits: `af1a79d` (work-stage run), `33bf8f2` (merge), `4b22d20` (cross-field consistency hardening), `3d28f09` (P2 tails).
