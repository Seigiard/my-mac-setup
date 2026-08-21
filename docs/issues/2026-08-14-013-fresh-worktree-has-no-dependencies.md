---
title: "A fresh run worktree has no installed dependencies, so any JS validate-cmd fails with exit 127"
short_description: "A fresh run worktree has no installed dependencies, so any JS validate-cmd fails with exit 127"
type: "bug"
category: "testing-ci"
tags: ["testing-ci","bug"]
date: "2026-08-14"
status: "done"
priority: "low"
closed: "2026-08-14"
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

## Resolution

Both halves shipped: a preflight probe that refuses before the work leg, and a gate reason that names the missing binary when a run gets there anyway.

**The probe.** A new `probe` node runs in the staged worktree right after `setup` and before the work agent is dispatched (`home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx`). Its classification lives in `home/private_dot_claude/dot_smithers/workflows/lib/validate-probe.ts`: `splitSegments` cuts the validate-cmd on `&&`, `||`, `;`, `|`, newline and subshell parens while respecting quotes; `segmentHead` strips leading environment assignments and takes each segment's first word; `probeValidateCmd` asks the injected resolver about every head. The resolver is `command -v` executed through `runValidateCmd`, the same login-shell wrapper the real validate-cmd runs under, so what the probe sees is what the gate would see. A missing head throws with `missingRunnerMessage`, which names the binary and both escape routes (`--setup-cmd`, a package-manager-resolved `--validate-cmd`).

Ordering matters and is deliberate: the probe runs *after* `setup`, because `--setup-cmd` is what installs the runner.

False positives were the design risk, and the probe refuses only what it is sure about. A head containing a variable, a command substitution, a glob or a quoted span is unreadable statically and is skipped. A command that provisions itself is not judged at all — `selfProvisioning` looks for `install`/`ci`/`sync`/`bootstrap`/`setup`/`build`/`compile`/`restore` in any segment, or a `make` head — because `bun install && vitest run` has no `vitest` at probe time and a working command must not be refused.

Verified against the real failing command from `run-1786717826270`, through the real shell wrapper:

```
$ cd home/private_dot_claude/dot_smithers && bun -e '
const { runValidateCmd } = await import("./workflows/lib/envelopes.ts");
const { probeValidateCmd, shellQuote } = await import("./workflows/lib/validate-probe.ts");
const os = await import("node:os");
const resolves = (h) => runValidateCmd(`command -v -- ${shellQuote(h)} >/dev/null 2>&1`, os.tmpdir(), 30000).exitCode === 0;
for (const cmd of ["vitest run --config scripts/vitest.config.ts", "bun test", "bun install && vitest run", "(bun test) && (tsc)"])
  console.log(JSON.stringify(cmd), "->", JSON.stringify(probeValidateCmd(cmd, resolves)));'

"vitest run --config scripts/vitest.config.ts" -> {"probed":["vitest"],"missing":["vitest"],"skipped":false}   10ms
"bun test"                                     -> {"probed":["bun"],"missing":[],"skipped":false}              8ms
"bun install && vitest run"                    -> {"probed":[],"missing":[],"skipped":true}                    0ms
"(bun test) && (tsc)"                          -> {"probed":["bun","tsc"],"missing":[],"skipped":false}        15ms
```

Ten milliseconds against forty minutes and one paid work leg.

**The gate reason.** `describeValidateFailure` in `home/private_dot_claude/dot_smithers/workflows/lib/gates.ts` replaces the bare exit-code string. `WorkGateInput` gained `validateOutput`, read for one purpose: telling a missing runner apart from a failing test. On 127 with `command not found` in the output it names the binary and points at `--setup-cmd`. `runValidateCmd` also returns 127 when it kills the command group on timeout, so that case is detected by its own marker and reported as a termination, not as a missing binary — and 127 with no output claims neither. The rescan gate reuses the same helper.

**What was not built.** The launcher-side refusal (`se pipeline` rejecting a JS-looking validate-cmd with no `--setup-cmd`) was dropped: the probe subsumes it and is strictly better informed, because it inspects the worktree after provisioning rather than guessing from the command string. Deriving a setup command from a lockfile was also dropped — it spends install time on every run, including runs that need none, and the probe makes the missing case loud enough that the operator can add the flag in one round trip.

Suite: 419 pass, 0 fail (18 new in `validate-probe.test.ts`, 4 in `gates.test.ts`). All five workflows still construct (`workflow-construction.test.ts`), and `bunx smithers-orchestrator graph workflows/se-pipeline.tsx` loads with the new `probe` output key. Runbook updated (`docs/se-pipeline.md`, validate-cmd section).

Uncovered: no live pipeline run has executed the probe node yet. The classification and the resolver are proven by the trace above; the node's placement in the graph is proven by construction only.

**Explicitly NOT covered: a missing built dist.** The probe catches a missing *runner*, which exits 127. It does not catch a present runner whose tests then fail to resolve a workspace package's build output, which exits 1 and is indistinguishable at the gate from a real test failure. `run-1786718288581` failed exactly that way — `bun` resolved, and `workload-comparison/result.test.ts` died on `Cannot find module …/@membranehq/sdk/dist/index.node.js` inside the staged worktree — after this fix was written and before it was delivered. That gap is `docs/issues/2026-08-14-019-worktree-missing-built-dists-is-not-detected.md`.
