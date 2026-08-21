---
title: Pre-external secret boundary for coding-agent pipelines
date: 2026-08-14
last_updated: 2026-08-21
category: architecture-patterns
module: se-pipeline
problem_type: architecture_pattern
component: development_workflow
severity: high
resolution_type: workflow_improvement
related_components:
  - tooling
applies_when:
  - "Shipping repo content, diffs, or snapshots to external LLM review/simplify legs"
  - "Adding a pipeline stage or harness that exports git content off the local machine"
  - "Wiring a secret scanner (gitleaks) whose exit codes gate a pipeline stage"
  - "Writing scanner output into durable run summaries or envelopes"
  - "Operating in a repo that legitimately tracks secret-reference templates (op:// paths)"
symptoms:
  - "Run commits could reach external claude/opencode legs with no secret scan between commit and export"
  - "Standalone se-code-review/se-simplify harnesses ship a git-stash-create snapshot externally with no scan"
tags:
  - secret-scanning
  - gitleaks
  - se-pipeline
  - external-llm
  - security-boundary
  - smithers
  - exit-code-contract
  - redaction
---

# Pre-external secret boundary for coding-agent pipelines

## Context

The se-pipeline (the durable Smithers pipeline under `home/private_dot_claude/dot_smithers/workflows/`) ships repo content to external LLM legs: the simplify stage and verify-code each dispatch full independent claude/opencode runs that read the staged worktree. Anything committed on the run branch — including an accidentally committed credential — would leave the machine with them.

The pipeline treats that hand-off as a security boundary: before any external leg dispatches, it secret-scans the run's own commits with gitleaks, and it re-scans whenever new commits appear (pipeline-committed simplify edits, operator hand-commits during an approval pause). The scan is a first-class pipeline stage with a gate, not an ad-hoc check.

The design was not right on the first try (session history):

- The original simplify plan gave simplify its **own** stage-specific scan and placed simplify **before** the pipeline's secret-scan stage — the external report legs would have shipped repo content before the shared scan ran. The boundary was backwards; it was caught during plan review (the OQ6 discussion, prompted by the user asking whether code-review and doc-review can also leak) and fixed in-plan: one shared barrier owned by the pipeline, simplify strictly after it.
- The first compute-block implementation let the flow spec supply the scan base (`input?.baseShaRef ?? ctx.baseSha`) — a composer could name HEAD, shrink the diff to an empty range, and get a green gate on a scan that inspected nothing. Both independent review legs flagged it as P0.
- An empty `baseSha..HEAD` range originally reported `clean`; it now reports `error` — a scanner that inspected zero commits has proven nothing.

The core primitive is `secretScanDiff` in `home/private_dot_claude/dot_smithers/workflows/lib/envelopes.ts:84`:

```ts
export type SecretScanState = "clean" | "found" | "error";

// Scans only the run's own commits (baseSha..HEAD). Exit codes are pinned via
// --exit-code so a scanner crash is never confused with a clean pass: 0 clean,
// 2 leaks, anything else (missing binary, timeout, git errors) = error →
// degraded at the gate (KTD10).
export function secretScanDiff(
  repo: string,
  baseSha: string,
  opts: { bin?: string; timeoutMs?: number } = {},
): SecretScanResult {
  const bin = opts.bin ?? "gitleaks";
  const res = spawnSync(
    bin,
    // --redact: gitleaks otherwise echoes the raw secret into its report, which
    // this pipeline persists to the run summary and report files — redact so a
    // detected secret is never copied into a durable store.
    ["git", "--no-banner", "--redact", "--exit-code", "2", `--log-opts=${baseSha}..HEAD`, repo],
    { encoding: "utf8", timeout: opts.timeoutMs ?? 2 * 60_000 },
  );
  const output = `${res.stdout ?? ""}${res.stderr ?? ""}`;
  if (res.error || res.status === null) {
    return { state: "error", details: `${res.error ? String(res.error) : "scanner terminated (timeout or signal)"}` };
  }
  if (res.status === 0) return { state: "clean", details: output.trim() };
  if (res.status === 2) return { state: "found", details: output.trim() };
  return { state: "error", details: `gitleaks exited with unexpected code ${res.status}: ${output.trim()}` };
}
```

Call sites in `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx`:

- **:761** — the `secret-scan` stage runs after the work stage goes green and before simplify/verify-code, "BEFORE anything is sent to external LLMs" (comment at :754). Only `state: "clean"` gates green; both `found` and `error` degrade (:771-779).
- **:845** — `simplify-rescan`: when the pipeline commits simplify's applied edits, it re-scans that new commit before verify-code's external legs run, using the prior scan's `scannedHead` as base when ancestry holds, falling back to `baseSha` otherwise (:838-845).
- **:1000** — the post-approval `rescan`: operators hand-commit fixes on the run branch during the verify-code pause; those commits bypass the earlier scan, so if HEAD moved (or `scannedHead` is absent — fail-closed), the stage re-runs `secretScanDiff` plus the validate-cmd on the new commits (:947-1002).

The scan is also a reusable compute block (`secret-scan`) in the dynamic-flow block registry at `home/private_dot_claude/dot_smithers/workflows/lib/blocks/index.ts:38`, with an empty input schema on purpose: a composer-supplied base could name HEAD and shrink the scan to an empty range that reports clean, so the base always comes from the staged worktree, never from spec data. Its `gateFn` passes only on `"clean"` — "a leak or scanner error is never a pass". The flow validator additionally rejects any flow where an external review block is not preceded by a secret scan, and the `pr` block carries a `publishes` flag with a scan-before-publish invariant (session history; validator tests in `flow-validate.test.ts`).

## Guidance

Six transferable rules for any pipeline that sends repo content to an external service:

1. **Scan before anything crosses the external boundary — at every path that crosses it.** The scan belongs immediately upstream of the dispatch, and every dispatch path needs one: the initial external legs (`se-pipeline.tsx:761`), content added by the pipeline itself (simplify commit → `:845`), and content added by a human mid-run (approval-pause commits → `:1000`). A single scan at the start is not a boundary if commits can appear after it.

2. **Pin scanner exit codes and map "anything unexpected" to error — never clean.** `secretScanDiff` pins the leak exit code with `--exit-code 2` and treats exit 0 as the only clean signal; a missing binary, timeout, git error, or null status all become `state: "error"` (`envelopes.ts:99-104`), which the gate turns into degraded, not green. Without pinning, a scanner crash (often exit 1 or 127) is indistinguishable from "no findings" in tools where nonzero can mean either.

3. **Redact scanner output before persisting it — the report must not become the leak.** The pipeline stores scan details in durable run summaries and report files, so it runs gitleaks with `--redact` (`envelopes.ts:92-95`). A secret boundary that copies the detected secret verbatim into its own logs has just moved the leak, not stopped it.

4. **Scope the scan to the run's own commits (`baseSha..HEAD`).** The `--log-opts=<baseSha>..HEAD` range means pre-existing tracked secrets that were already in the repo — and are not part of what this run produced — don't false-block every run. Trade-off, named: this deliberately does NOT protect content that predates the run. If the external leg reads the whole worktree (it does), tracked secrets from before `baseSha` still ship; the diff scan only guarantees the run added no new ones. Full-tree exposure got its own control on 2026-08-15: a two-tier boundary in `home/private_dot_claude/dot_smithers/workflows/lib/pre-external-gate.ts` — tier 1 `preExternalRepoGate` (range scan) plus tier 2 `preExternalTreeGate` (`git archive` + gitleaks over the whole tree at the snapshot commit, `pre-external-gate.ts:103`) — wired into se-code-review, se-simplify, and the pipeline's secret-scan stage (`docs/issues/2026-08-14-009-snapshot-base-tree-unscanned.md`, done).

5. **Never let untrusted input choose the scan scope, and fail an empty scan closed.** The scan base comes from the trusted staged worktree, never from flow-spec data — the spec-controlled base was a P0 precisely because it let a composer neutralize the scan (session history; fix in commit `46d3a46` "Fix three P0 findings in the compute-effect bodies", empty-range-fails-closed covered by tests in `block-effects.test.ts`).

6. **A pause invalidates every earlier check — not just the secret scan.** Any window where a human (or the pipeline itself) can edit state converts every prior verdict into a statement about a tree that may no longer exist: the secret scan AND the validate-cmd both attested to a specific head. The mechanism: each check stamps the head it attested (`scannedHead` written into the scan's report JSON, `se-pipeline.tsx:755`, `:765`); after the pause, a rescan compute re-derives `currentHead` and sets `moved = scannedHead === undefined || currentHead !== scannedHead` — an absent stamp is treated as moved, never as a pass (`se-pipeline.tsx:988-997`). The pure verdict function `rescanGate` (`home/private_dot_claude/dot_smithers/workflows/lib/gates.ts:406-436`) fails closed at every branch: no report → failed; moved with a leak or scanner crash → degraded; moved with validate-cmd missing or red → failed; unmoved head → deterministic no-op green. Approve on a red rescan means **one fresh attempt, not a waive** (`waiveOnApprove: false`, `se-pipeline.tsx:1021`): the operator's natural response to red is "commit the fix and approve", and that fix-commit must itself be scanned — a waive shape can never close that recursion.

   Corollary, and the reason the rescan cannot be replaced by provenance machinery: **provenance binds guard scheduling, not history.** The pipeline's ProofBinding chain (`ctx.prove` at `se-pipeline.tsx:309`, `bind=` on every expensive leg) re-verifies only at render and immediately before dispatch — a memoized, finished task never re-verifies its bind (`docs/se-pipeline.md:682-690`). Binds park not-yet-dispatched tasks as `BOUND_STALE` when an authority row is tampered; only an explicit state-comparison rescan protects against edits made during a pause. Each guard has a precise blind spot: row tamper → bind; plan-file edit → the work gate's re-hash; pause edit → rescan.

## Why This Matters

- External LLM legs are an exfiltration path: whatever the leg can read, a third-party service receives. Treating "before dispatch" as a gated boundary makes the exposure auditable and stoppable.
- The failure modes this design closes are the quiet ones: a scanner that isn't installed in the environment silently "passing" (rule 2), a leak reproduced verbatim in a persisted report (rule 3), a mid-run commit that slips out after the one-and-only scan (rule 1), and a scan whose scope was quietly narrowed to nothing (rule 5).
- The scoping rule keeps the control usable. This repo is a chezmoi dotfiles tree that legitimately tracks secret-referencing templates — `home/dot_zshenv.tmpl:72-75` contains `op://` 1Password references (`onepasswordRead "op://Private/Linear API Key/credential"` etc.). An unscoped full-history scan would flag these on every run and train operators to waive reflexively.
- The boundary has caught a real (deliberate) leak in production: a run parked `degraded` at the secret-scan gate on a fake private key embedded in a test file; the finding was confirmed manually, approved as a known fake, and the fixture annotated so it stays clean — the scanner was not weakened (session history, 2026-08-13).

## When to Apply

- Any workflow that snapshots or stages repo content and hands it to an external model, API, or service — review harnesses, simplify/refactor legs, cloud CI agents.
- When adding a new external-dispatch path to an existing pipeline: the new path needs its own scan (or must provably run behind an existing one on the same content).
- When a run can gain commits after its first scan (agent-applied edits, operator commits during pauses): add a rescan keyed to HEAD movement, fail-closed when the previously scanned SHA is unknown or ancestry is broken.
- When wiring any third-party scanner into a gate: pin its exit-code contract explicitly and route every unexpected outcome to error/degraded.

## Examples

**Covered (the pipeline path).** Work goes green → `secret-scan` on `baseSha..HEAD` (`se-pipeline.tsx:756-781`) → simplify's external report legs only see content the scan cleared (:787-789) → if simplify commits edits, `simplify-rescan` covers just that commit (:833-861) → after verify-code approval, `rescan` catches operator commits made during the pause (:971-1015), and its approve semantics force a fresh scan attempt rather than a waive, because the fix-commit itself must be scanned (:1008-1014).

**Known operational hole (session history).** Because secret-scan is nested inside the work stage's green branch, a run parked at the work gate never scans; merging a branch from such a run means the diff was never scanned. The observed compensation was a manual grep pass over the diff (api key/token/`sk-`/`ghp_`/`AKIA`/private-key headers/`op://` patterns) before merging.

**Former gap (standalone harnesses) — CLOSED 2026-08-14** (`docs/issues/2026-07-27-002-standalone-harness-secret-boundary.md`, done). Standalone `se-code-review` / `se-simplify` used to snapshot the repo via `git stash create` and ship it to external legs with no scan. The shared pre-external gate shipped in `home/private_dot_claude/dot_smithers/workflows/lib/pre-external-gate.ts` (`enforcePreExternalGate`, `pre-external-gate.ts:197`; callers hold a `preScanned` flag and skip the gate on the already-scanned pipeline path, so it is not double-scanned) and both standalone harnesses now pass through it before their `Parallel` legs dispatch (tests: `pre-external-gate.test.ts`, `standalone-secret-gate.test.ts`). The follow-up tree-tier (`preExternalTreeGate`) closed the pre-`baseSha` exposure on 2026-08-15 (`docs/issues/2026-08-14-009-snapshot-base-tree-unscanned.md`, done).

## Related

- `docs/issues/2026-07-27-002-standalone-harness-secret-boundary.md` — the standalone-harness gap (done, closed 2026-08-14).
- `docs/issues/2026-08-14-009-snapshot-base-tree-unscanned.md` — the tree-tier scope decision (done, closed 2026-08-15).
- `docs/plans/2026-07-16-001-feat-se-pipeline-provenance-rescan-plan.md` — the plan (status: done) behind rule 6: `scannedHead` threading, `rescanGate`, provenance binds; its KTD-C (`waiveOnApprove: true`) is superseded on that one point by the shipped `waiveOnApprove: false`.
- `docs/se-pipeline.md` — runbook: secret-scan required before every external block (se flow catalog), "Провенанс и пост-approval рескан" (`:657-713`) with the `BOUND_STALE` recovery notes and acceptance recipes.
- `docs/plans/2026-07-27-001-feat-se-simplify-and-work-fork-plan.md` — the plan (status: done) that fixed the boundary ordering and deferred the standalone case.
- `home/private_dot_claude/dot_smithers/workflows/lib/envelopes.ts` — `secretScanDiff` implementation; `home/private_dot_claude/dot_smithers/workflows/lib/gates.ts` — `rescanGate` (`:406-436`); `home/private_dot_claude/dot_smithers/workflows/lib/pre-external-gate.ts` — the two-tier standalone gate.
- `../design-patterns/gate-bias-follows-blast-radius.md` — the fail-closed bias family this boundary's gates inherit; also covers why only applied simplify edits trigger the commit+rescan machinery.
