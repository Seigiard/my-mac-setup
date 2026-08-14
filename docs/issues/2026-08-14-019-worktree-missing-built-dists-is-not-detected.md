---
title: A worktree missing built workspace dists fails the work gate as a test failure, and no preflight catches it
type: bug
date: 2026-08-14
status: open
---

# The runner is present, the built dist is not, and the gate reads it as a failing test

## Why this exists

`run-1786718288581` failed both work gates. The reason, from the durable verdict row:

```
$ sqlite3 ~/.claude/.smithers/smithers.db \
  "SELECT reasons FROM gate_verdict WHERE run_id='run-1786718288581' AND node_id='gate-work-extra';"
validate-cmd exited with code 1; validate-cmd output tail:
 FAIL  workload-comparison/result.test.ts
Error: Cannot find module '/private/var/folders/…/T/se-pipeline/se-2026-08-14-001-fix-prepush-format-ignore-18288581/engine/api/node_modules/@membranehq/sdk/dist/index.node.js'
error: script "test:scripts" exited with code 1
```

The path is inside the staged run worktree. The module is a workspace package's build output, which a fresh `git worktree` does not contain. The same command in the operator's main checkout passes: 33 files, 521 tests. In the worktree: 32 files, 517 tests, one suite failing. The failing suite is untouched by the branch.

**The preflight added for the sibling defect does not catch this.** `docs/issues/2026-08-14-013-fresh-worktree-has-no-dependencies.md` added a probe that resolves the validate-cmd's head words with `command -v` in the staged worktree. Here the head word is `bun`, which resolves. The command starts, runs, and fails at exit code 1 — indistinguishable at the gate from a genuine test failure. Runner absence exits 127 and is now caught before any spend; build-artifact absence exits 1 and is caught only after a full work leg.

**The remedy is documented and was not used.** `--setup-cmd` exists precisely for this: the runbook's validate-cmd section says a worktree contains no built dists and gives `--setup-cmd 'bun install && bunx turbo run build --filter=<pkg>'` as the fix. Nothing in the launch path connects a plan whose tests import workspace dists to the flag that would build them. The operator launches, waits, pays, and reads a gate reason that names a failing test.

**The cost.** $1.83 and two work legs on this run, and the work itself was correct — the branch `se/2026-08-14-001-fix-prepush-format-ignore-18288581` holds the intended two-file diff. A correct change was reported as a failed run because of an environment gap the pipeline knew about in its own documentation.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` — the setup stage and the probe node added for issue 013.
- `home/private_dot_claude/dot_smithers/workflows/lib/validate-probe.ts` — where a deeper preflight would live.
- `home/private_dot_claude/dot_smithers/bin/executable_se` — the launcher, if the answer is to ask the operator.

## Open decisions

- **Whether the validate-cmd should be dry-run in the worktree before the work leg.** It is the only check that catches this class with certainty, because the failure is a module resolution at test time. It costs one full validate-cmd execution up front — seconds to minutes, against a work leg — and it must not be confused with the real gate run afterwards.
- **Or whether a missing `--setup-cmd` should be refused when the repo looks like a workspace.** A lockfile plus a workspace field is a cheap signal, and refusing at launch costs nothing. It also refuses runs whose tests need no dist, which is most of them.
- **Or whether provisioning should simply be the default.** `bun install` in the staged worktree on every run removes the common half of this class. It does not remove the dist half, which needs a build the pipeline cannot guess.
- **Separately: the gate reason should distinguish a resolution failure from an assertion failure.** "Cannot find module" inside the output is a strong signal that the environment, not the code, is at fault, and the gate has the output in hand (`validateOutput` on `WorkGateInput`, added in issue 013). Naming it would have saved this run's second attempt, which repeated the same environment failure.
