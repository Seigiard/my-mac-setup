---
title: A fresh run worktree has no installed dependencies, so any JS validate-cmd fails with exit 127
type: bug
date: 2026-08-14
status: open
---

# A fresh run worktree has no dependencies, so the work gate fails on a missing binary

## Why this exists

`gate-work` on `run-1786717826270` failed for two independent reasons. The second one:

```
validate-cmd exited with code 127; validate-cmd output tail: $ vitest run --config scripts/vitest.config.ts
/bin/bash: vitest: command not found
```

The pipeline stages the run in a new `git worktree`. A new worktree contains tracked files only — no `node_modules`, no built dists, no virtualenv. Every JavaScript validate-cmd resolves its runner from `node_modules/.bin` through the package manager, so in a fresh worktree it is simply absent. Exit 127 is "command not found", not a failing test.

The pipeline already has the remedy: `--setup-cmd` runs a provisioning command in the staged worktree before work, and its own input schema names the case ("For validate-cmds that need built workspace dists"). The problem is that nothing connects the two. The operator launches `se pipeline <plan>`, the plan's Verification Contract supplies a validate-cmd, and no one asks who installs its dependencies. The failure then arrives forty minutes and one paid work leg later, wearing the label "validate-cmd exited with code 127" at a gate that talks about the agent's work.

This is not the same defect as the empty worktree recorded in `docs/issues/2026-08-14-012-work-agent-escapes-the-isolated-worktree.md`; the two happened to fire on the same run. Either one alone fails the gate.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` — the setup stage and the work gate's reporting.
- `home/private_dot_claude/dot_smithers/bin/executable_se` — the launcher, which is where an operator would be told before paying for a work leg.

## Open decisions

- **Detect the missing runner before the work leg, not after.** A dry probe of the resolved validate-cmd in the staged worktree costs seconds and turns a late red gate into an immediate, actionable refusal. `command -v` on the command's head word is enough for the common case.
- **Or provision by default.** If the target repo has a lockfile, the obvious setup-cmd is derivable (`bun install`, `npm ci`, `pnpm install --frozen-lockfile`). Deriving it removes the footgun but spends install time on every run, including runs whose validate-cmd needs nothing.
- **Or make the launcher ask.** `se pipeline` could refuse a JS-looking validate-cmd with no `--setup-cmd`, naming the flag. Cheapest to build, and it puts the decision where the operator already is.
- **Separately: exit 127 deserves its own gate reason.** "validate-cmd exited with code 127" reads as a test failure to anyone who has not memorised shell exit codes. The gate should say the command was not found and name the missing binary.
