---
title: External legs read the whole snapshot tree, but only the branch range is scanned
type: follow-up
date: 2026-08-14
status: done
closed: 2026-08-15
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

## Resolution

The boundary is now two-tiered. Tier 1 (the commit range) is unchanged. Tier 2 is a new
`preExternalTreeGate` in `lib/pre-external-gate.ts`: it exports the git tree at the snapshot
commit with `git archive` into a temp directory, scans it with `gitleaks dir` run at
`cwd = <export root>` with target `.`, and removes the export on both the pass and the refuse
path. Wired into `se-code-review.tsx` and `se-simplify.tsx` immediately after the range gate and
before `git worktree add`, and into `se-pipeline.tsx`'s `secret-scan` stage, where the tree
verdict rides into the existing `gateFn` (finding → degraded → the existing waive-on-approve
Approval) rather than throwing. `se-doc-review` is unchanged — it ships one document and
`preExternalDocGate` already scans that file.

**Is a full-tree scan gated on a per-repo baseline worth the setup toll?** Yes. The toll is one
loud pass on a repo's first run, and it buys the only coverage of a secret that was on the base
branch before the run. Measured on this repo through the shipped code path: the tracked tree at
HEAD carries 3 findings (`configs/MTMR/items.json:generic-api-key:75`,
`workflows/lib/issue-writer.test.ts:generic-api-key:65`,
`workflows/lib/block-effects.test.ts:private-key:132`) — the same three this issue predicted
would survive into a snapshot. The 48 findings quoted above come from `gitleaks dir` over the
whole working checkout, which walks untracked and ignored content the legs never receive; the
tree tier does not scan that. A planted credential committed in a scratch clone was refused by
name against that same baseline.

**Where does the baseline live for repos that are not this one?** Cached beside the harness
state, never committed in the target: `~/.claude/.smithers/state/secret-baseline/<repo-basename>-<first
12 hex of sha256 of the absolute repo path>.json` (`lib/secret-baseline.ts`). Target repos belong
to other people and other agents, and writing a `.gitleaksignore` into one would change that
repo's content, its git status, and every future non-harness scan of it. The key is the
*repository*, resolved through `git rev-parse --git-common-dir`, not the path handed in: a
pipeline run scans its own `.worktrees/<run>`, and keying on that would mint a fresh baseline —
hence auto-approve every finding — on every single run.

**Should `se-simplify`'s apply-leg forbidden-paths denylist be reused as a snapshot denylist?**
Not adopted. The gate refuses rather than filters, so the reviewers always see the same tree the
repo has. Excluding files from the snapshot would hand the external legs a tree that silently
differs from the repository and a review claiming coverage it never had — the same reason the
original standalone gate refuses instead of dropping the offending file. The denylist stays what
it is: a bound on what the apply leg may edit.

Known gap left open deliberately: the pipeline's `simplify-rescan` and post-approval `rescan`
stages remain range-only. They cover commits added after the tree tier already cleared the whole
tree, and a new commit's content is exactly what a range scan sees.

## Reference

- Closed predecessor: `docs/issues/2026-07-27-002-standalone-harness-secret-boundary.md` (the standalone gate itself).
- Vocabulary: `CONCEPTS.md` → "Secret boundary".
