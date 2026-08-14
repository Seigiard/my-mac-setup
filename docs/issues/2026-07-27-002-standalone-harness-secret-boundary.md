---
title: Pre-external secret boundary for standalone se-* harnesses
type: follow-up
date: 2026-07-27
status: done
closed: 2026-08-14
parent-plan: docs/plans/2026-07-27-001-feat-se-simplify-and-work-fork-plan.md
---

# Pre-external secret boundary for standalone se-* harnesses

## Why this exists

The se-pipeline (`home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx`) secret-scans the run branch diff **before anything is sent to external LLMs** (KTD10). So pipeline stages that ship repo content to external claude/opencode legs — verify-code, and now the simplify stage (parent plan) — are covered: they run after that shared scan.

The **standalone** harnesses have no such gate. When `se-code-review` or `se-simplify` run directly (outside the pipeline), they stage a `git stash create` snapshot of the repo into `/tmp/...` and send it to external legs (opencode reads it via `permission.external_directory`). `stash create` excludes untracked files, but **tracked** secrets still go out — and this repo is a chezmoi dotfiles tree that legitimately tracks secret-bearing files (`dot_zshenv.tmpl` with `onepasswordRead` / `op://` references, permission configs). There is no pre-external secret scan on the standalone path.

The parent plan deliberately did not solve this (it reused the pipeline's shared scan for the pipeline path and deferred the standalone case here) to avoid scope creep.

## Scope

- `se-code-review.tsx` standalone stage → external legs.
- `se-simplify.tsx` standalone stage → external legs (parent plan).
- `se-doc-review.tsx` ships only the plan document (a read-only copy), not the repo — lower exposure, but a plan could contain a pasted secret; decide whether to scan the doc too.

## Design direction

A shared pre-external secret gate (reuse `secretScanDiff` / the scanning primitive from `lib/envelopes.ts`) invoked by the standalone harness `stage()` before the external `Parallel` legs dispatch — mirroring what the pipeline does before verify-code. On a hit: refuse (stop the standalone run with the finding) or filter the offending file from the snapshot; align the refuse-vs-filter choice with the parent plan's apply-leg denylist policy (parent R10).

## Open decisions

- **Refuse vs. filter on a hit** (same fork the parent plan resolved for the apply-leg denylist — reuse that decision for consistency).
- **Whether `se-doc-review` scans the doc** (low exposure; possibly not worth it).
- **Where the shared gate lives** so all three standalone harnesses call one implementation (candidate: extend `lib/staging.ts` or `lib/envelopes.ts`).

## Reference

Parent plan: `docs/plans/2026-07-27-001-feat-se-simplify-and-work-fork-plan.md` (R10, KTD-H, OQ6 — the pipeline path is solved there; this issue is the standalone gap). Pipeline precedent: KTD10 secret-scan + `secretScanDiff` in `lib/envelopes.ts`.

## Resolution

A shared pre-external secret gate now runs in all three standalone harnesses, before any repo or document content is staged for the external claude/opencode legs.

**What was added**

- `home/private_dot_claude/dot_smithers/workflows/lib/pre-external-gate.ts` — the policy: `preExternalRepoGate` (snapshot range), `preExternalDocGate` (one document), `enforcePreExternalGate` (throws on refusal, logs a passing scan into the run log), `SE_SKIP_SECRET_SCAN` as the operator override.
- `lib/envelopes.ts` — the scanning primitive stays one implementation. `secretScanDiff` gained `head` and `includeMergeDiffs`; `secretScanPath` (`gitleaks dir`) was added for a document that has no commit range; both share one `runGitleaks` spawn with the pinned `--exit-code 2` and `--redact` contract.
- `se-code-review.tsx`, `se-simplify.tsx`, `se-doc-review.tsx` — gate call in `stage()`, before `worktree add` / `copyFileSync`, with `retries={0}` on the stage task so a refusal fails once instead of re-scanning.
- `se-pipeline.tsx` — passes `preScanned: true` into the simplify Subflow.

**A blind spot found while building it, and fixed**

`git stash create` produces a MERGE commit, and `git log -p` prints no patch for merges. Scanning `base..<stash>` the way the pipeline scans `base..HEAD` reported **clean while scanning zero commits** — the dirty tracked content the harnesses actually ship would have gone out unscanned. `includeMergeDiffs` adds `--diff-merges=first-parent`, which diffs the stash against HEAD. Measured on gitleaks 8.30.1; both halves are pinned by a regression test in `lib/envelopes.test.ts`.

**Open decisions, decided**

1. **Refuse, not filter.** Filtering a flagged file out of the snapshot would hand the reviewers a tree that silently differs from the repo, and a report claiming coverage it never had. Refusal is fail-closed and visible, and it costs a standalone operator one message. It also matches the parent plan's R10 spirit: the apply leg refuses to touch denylisted paths rather than editing them carefully. A scanner that cannot run (missing binary, timeout) is likewise a refusal — an unscanned snapshot is the exact state this gate exists to prevent. Because a standalone run has no approval pause to waive at, the override is explicit and per-invocation: `SE_SKIP_SECRET_SCAN=1`.
2. **Yes, `se-doc-review` scans the document.** The doc is the entire payload on that path, and the false-positive cost was measured, not assumed: `gitleaks dir` over `docs/` (591 KB of plans and issues, full of `op://` references) returns zero findings. The repo is not scanned there — it is read-only context for the legs.
   Side effect worth knowing: the pipeline's `verify-doc` stage runs this same harness, so a pipeline run now also refuses a plan document that trips gitleaks. That is deliberate — the plan reaches the external legs on both paths, and the pipeline's own repo scan never covered it.
3. **The gate lives in its own module** (`lib/pre-external-gate.ts`), not inside `staging.ts` or `envelopes.ts`. `envelopes.ts` keeps the scanning primitives, the new module keeps the refuse/override policy, and all three harnesses plus any future one call the same two functions. `staging.ts` was rejected as the home because two of the three harnesses do not use it.

**Why `preScanned` exists.** Without it the pipeline would double-gate: its secret-scan stage can be waived by the operator at an approval, and the simplify subflow's own gate would then re-refuse the very range the human just decided to accept, stopping the run. `se-flow` does not pass it, so its simplify dispatch stays gated — that block is declared `external: false`, so the flow validator does not require a secret-scan ancestor for it.

**Verification**

- `cd home/private_dot_claude/dot_smithers && bun test` → 392 pass, 0 fail, 25 files (was 387/24). New: `lib/pre-external-gate.test.ts` (13 tests — clean/found/error/empty-range/override, real-gitleaks stash-snapshot leak and clean-tree cases, enforce throws vs logs), `lib/standalone-secret-gate.test.ts` (5 wiring tests asserting the gate call precedes `worktree add` / `copyFileSync` in each harness and that the pipeline passes `preScanned: true`), plus the merge-diff regression and `secretScanPath` tests in `lib/envelopes.test.ts`.
- Live check against this repo's real working state (uncommitted changes included): `preExternalRepoGate` over `merge-base(origin/main, stash-snapshot)..stash-snapshot` returned `pass` — the gate does not false-refuse the dotfiles tree it was written for.
- `make lint` (shellcheck) clean from the repo root.
- Not verified: no end-to-end `smithers up` run of a harness. The live pipeline run occupying `~/.claude/.smithers` was off-limits, so harness wiring is covered by the source-order tests and the import-time construction test, not by a live dispatch.

**Residual, filed separately.** Both boundaries scan a commit range, while the external legs read the whole snapshot tree — a secret already committed on the base branch is never scanned. A full-tree scan was measured and rejected for now (48 findings on this repo, 3 of them inside a snapshot), because a gate that refuses every run is not a boundary. Tracked in `docs/issues/2026-08-14-009-snapshot-base-tree-unscanned.md`.
