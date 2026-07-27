---
name: se-simplify
description: Simplify recently changed code with cross-model verification — runs the compound-engineering ce-simplify-code reviewers as TWO independent report-only legs (claude + opencode) on a frozen snapshot, synthesizes their consensus, then applies it ONCE and verifies behavior is preserved via a required validate-cmd. Use for a tidy/refactor pass on a branch before review; use ce-debug for bugs.
argument-hint: "validate-cmd:'<test/typecheck command>' [blank to simplify current branch changes, or a scope description]"
---

# Simplify (wrapper: two cross-model report legs → single verified apply, via smithers)

Wrapper over `compound-engineering:ce-simplify-code`. Two external agents (claude on Sonnet, opencode on GPT-5.5) each run the ce-simplify-code **reviewer phase only** (Steps 1-2: scope + the reuse/quality/efficiency personas) on a **frozen snapshot** of the branch, returning findings and changing nothing. A deterministic merge keeps cross-model **consensus** + **unique** findings and **excludes contradictions**; then ONE workflow-owned apply leg (Sonnet) applies that set to the live repo, re-locating each finding by content, and a **validate-cmd** proves behavior is preserved — reverting the whole apply and degrading on failure.

All orchestration (right-sizing gate, snapshotting, staging, parallel launches, merge, apply, verify, revert) is **code**, not prose: the smithers workflow at `~/.claude/.smithers/workflows/se-simplify.tsx` (pinned `smithers-orchestrator`). Do not re-implement any of it — launch it and read its outputs.

**The workflow's apply leg is the SINGLE apply owner.** This wrapper does NOT run a separately-applying local `ce-simplify-code` pass: that would give two apply owners mutating the live repo while the report legs analyze a frozen snapshot (stale line refs, double/conflicting edits). Any local pass, if you want a third finding source, must run **report-only** and feed the synthesis; the workflow applies exactly once.

**Cost note:** two report legs (Sonnet claude + GPT-5.5 opencode, each up to 3 reviewer subagents) + one apply leg (Sonnet) + one validate-cmd run. Expect a few minutes and a few dollars on a normal branch diff; the apply leg's `maxBudgetUsd` is a runaway breaker, not a target. Skipped cheaply when the diff is not worth simplifying (the workflow's right-sizing gate).

## Recursion guard (read first)

If the current prompt contains the marker `[ce-simplify-external-consult]`, you ARE one of the external legs (a report leg or the apply leg). Do exactly what that prompt says — run the ce-simplify-code reviewers and return findings (report leg), or apply the provided finding set (apply leg) — and never launch the harness or another consult from inside it. (The harness embeds this marker in every consult prompt.)

## Phase 1: Resolve the scope and the REQUIRED validate-cmd

- **Resolve the repo:** the absolute path to the git checkout to simplify (default: the current working directory's repo root).
- **Resolve the validate-cmd (required):** the behavior-preservation command — the branch's test and/or typecheck command (e.g. `bun test`, `npm test && tsc --noEmit`). Take it from a `validate-cmd:'…'` argument token; if the user named a plan with a Verification Contract, derive it from there. **If you cannot resolve a validate-cmd, STOP and ask for one — do not launch a run that would refuse to apply.** Standalone `se-simplify` has no gate-0 / Verification Contract to supply a default, and applying simplifications without a way to prove behavior is preserved is not allowed.
- **Resolve the scope (optional):** any remaining description becomes the harness `target`. Empty = the current branch's changes vs the auto-detected base (the harness computes and freezes the merge-base itself).

## Phase 2: Launch the harness (background)

One background Bash task (`run_in_background: true`):

```bash
cd ~/.claude/.smithers && \
./node_modules/.bin/smithers up workflows/se-simplify.tsx \
  --input '{"repoPath":"<abs repo root>","validateCmd":"<the resolved command>","target":"<scope or empty>"}'
```

- Launch from `~/.claude/.smithers` — smithers drops its state there, outside the target repo (that directory's `.gitignore` ignores runtime state).
- `repoPath` is an **explicit input**, never an env default: the apply leg mutates exactly this path. Pass the real checkout you want tidied.
- The harness **freezes the review target** first (`git stash create` + a detached `git worktree` under `/tmp/ce-simplify/run-<ts>/repo`), so the report legs analyze a stable snapshot while the later apply leg edits the live repo. Staging lives under `/tmp/ce-simplify/`; opencode reads it via the `permission.external_directory` allow for `/tmp/ce-simplify/*` in `~/.config/opencode/opencode.json`. If the opencode leg fails with rejected reads, check that config.
- Add `"smoke":true` for a cheap wiring test (no real reviewers, no apply).

**Error handling:** each report leg is error-boundaried — a failed leg degrades to advisory, the surviving leg still produces a usable finding set. If **zero** legs succeed, the run reports `degraded` and applies nothing (never a clean success with an empty set). A failed post-apply validate-cmd reverts the whole apply and reports `degraded`.

## Phase 3: Collect the outcome

Wait for the background task, then read the final output block:

- `status`: `ok` (applied + verified, or nothing to apply), `skipped` (right-sizing gate — the diff was not worth simplifying; the reason is included), or `degraded` (zero legs, verify failure + revert, or refused-because-no-validate-cmd).
- `claudeStatus` / `opencodeStatus` (`ok` | `failed` | `n/a`), `appliedCount`, `contradictionCount`, `validateExitCode`, `reverted`, and a `reportPath` to the full synthesis (`simplify.report.json`).
- Diagnose a failed leg later with `./node_modules/.bin/smithers logs <runId>` / `smithers chat <runId>` from `~/.claude/.smithers`.

## Phase 4: Report what was applied

Summarize from the run output and the report:

- What the apply leg **applied**, by dimension (reuse / quality / efficiency), and whether the validate-cmd passed (behavior preserved) — or that the apply was **reverted** and why.
- **Consensus** findings (both legs agreed — the safest, applied), **unique** findings (one leg, attributed, applied), and **contradictions** (both legs touched the same spot with clashing edits — advisory only, NOT applied) so the user can decide those by hand.
- If `status: skipped`, state the gate's reason (empty / docs-only / borderline-below-threshold) — nothing was reviewed or applied.

`/tmp/ce-simplify/run-*` dirs are ephemeral tmp — leave them; the harness removes its own git worktree.
