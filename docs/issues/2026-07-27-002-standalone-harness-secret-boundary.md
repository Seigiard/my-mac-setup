---
title: Pre-external secret boundary for standalone se-* harnesses
type: follow-up
date: 2026-07-27
status: open
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
