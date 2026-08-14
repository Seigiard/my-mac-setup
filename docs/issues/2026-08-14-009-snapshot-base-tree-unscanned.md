---
title: External legs read the whole snapshot tree, but only the branch range is scanned
type: follow-up
date: 2026-08-14
status: open
---

# External legs read the whole snapshot tree, but only the branch range is scanned

## Why this exists

Both secret boundaries — the pipeline's (`se-pipeline.tsx`, KTD10) and the standalone one added for the harnesses (`home/private_dot_claude/dot_smithers/workflows/lib/pre-external-gate.ts`) — scan a **commit range**: base branch → the run's own content. What actually leaves the machine is larger: the external legs (claude, opencode) get a full checkout of the repository at the snapshot commit and can read every tracked file in it, including files the range never touches.

So a secret committed on the base branch before the run started is inside the snapshot and is never scanned. In this repo that is not hypothetical — it is a chezmoi dotfiles tree that tracks secret-bearing files by design (`dot_zshenv.tmpl` with `op://` references, permission configs).

The range-scoped scan was chosen deliberately, on measurement: a full-tree `gitleaks dir` on this repo returns 48 findings, and 3 of them survive into a `git stash create` snapshot (`workflows/lib/block-effects.test.ts`, `workflows/lib/issue-writer.test.ts`, `configs/MTMR/items.json` — all fixtures or false positives). A refuse-on-full-tree gate would therefore block every run here and in any repo carrying a test fixture that looks like a credential, which makes the harnesses unusable rather than safe.

## Scope

- `lib/pre-external-gate.ts` — the standalone gate for `se-code-review`, `se-simplify`, `se-doc-review`.
- `se-pipeline.tsx` secret-scan + rescan stages — the same range-scoped assumption.
- Any repo-wide answer needs a false-positive story first: a per-repo `.gitleaksignore` baseline, a `--baseline-path` report captured once per repo, or scanning only the file set the legs are told to read.

## Open decisions

- Is a full-tree scan gated on a per-repo baseline worth the setup toll, or is the honest answer "the snapshot is trusted content; the boundary only covers what the run adds"?
- If a baseline is adopted, where does it live for repos that are not this one — committed in the target repo, or cached beside the harness state?
- Should `se-simplify`'s apply-leg forbidden-paths denylist (parent plan R10) be reused as a *snapshot* denylist, i.e. files excluded from the staged copy rather than merely never edited? That changes what the reviewers see, which is why the gate refuses instead of filtering today.

## Reference

- Closed predecessor: `docs/issues/2026-07-27-002-standalone-harness-secret-boundary.md` (the standalone gate itself).
- Vocabulary: `CONCEPTS.md` → "Secret boundary".
