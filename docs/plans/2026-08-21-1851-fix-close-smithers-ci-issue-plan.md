---
title: Close Resolved Smithers CI Dependency Issue - Plan
type: fix
date: 2026-08-21
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Close Resolved Smithers CI Dependency Issue - Plan

## Goal Capsule

- **Objective:** Close repository issue `2026-08-18-022` after proving that the recorded GitHub continuous integration dependency failure no longer reproduces.
- **Means:** Land an evidence-backed structured issue closure without changing production or test code (KTD1).
- **Authority:** The issue output from `python3 scripts/issues show 2026-08-18-022 --json` defines the reported failure and closure scope.
- **Execution profile:** Use the isolated worktree, preserve the existing Smithers dependency setup, and validate the issue record plus pull request checks.
- **Stop conditions:** Stop the closure-only path if current source no longer contains the dependency setup, the cited default-branch run is stale or incomplete, or a pull request job reproduces `bun: command not found` or a missing Smithers binary. Require a fresh passing default-branch run before resuming when the cited evidence is no longer current.
- **Tail ownership:** The LFG pipeline owns the commit, push, pull request, and final GitHub Actions verification from the isolated worktree.

## Product Contract

### Summary

Close the still-open structured issue because current `origin/main` contains the dependency fix and a current default-branch run passes the exact setup, preflight, and downstream test steps on Ubuntu and macOS.

### Problem Frame

Repository issue `2026-08-18-022` records that checkout-based Smithers tests failed because GitHub Actions lacked Bun and `home/private_dot_claude/dot_smithers/node_modules/.bin/smithers`.
Commit `399d8e0` added the missing setup on 2026-08-18, but the issue was intentionally left open until a green default-branch run confirmed the fix.
The issue remains open even though current default-branch evidence now supplies that confirmation.

### Requirements

**Evidence and scope**

- R1. Reconfirm the issue state and failure description through `python3 scripts/issues show 2026-08-18-022 --json` before changing the record.
- R2. Treat the failure as non-reproducing only when current source retains the Bun setup, frozen source-tree install, both-directory preflight, and a current default-branch run passes those steps plus post-apply tests on Ubuntu and macOS.
- R3. Do not change `.github/workflows/test-dotfiles.yml`, Smithers runtime files, or tests when R2 remains true.

**Issue lifecycle and delivery**

- R4. Move issue `2026-08-18-022` through the repository issue command-line interface from `open` to `in-progress` and then `done` with an evidence-based resolution.
- R5. The resolution must identify commit `399d8e0`, default-branch run `32504078129`, any newer run required by the currency gate, and the successful Ubuntu and macOS dependency and post-apply test steps.
- R6. The resolution must record that the shipped fix chose direct source-tree dependency installation; caching and a stub validator remain unnecessary for correctness and outside this closure.
- R7. Validate the complete structured issue corpus after the closure mutation.
- R8. Ship the closure from the existing isolated worktree through a pull request whose `test-ubuntu`, `test-macos`, and `lint` jobs pass.
- R9. If a pull request job reproduces the original missing-Bun or missing-Smithers-binary failure, do not merge the closure-only change; return to the smallest correct dependency fix before closing the issue on the default branch.


### Key Decisions

- **Close through a pull request when current evidence proves non-reproduction.** (session-settled: user-directed — chosen over forcing a code change: the user required evidence-based closure when the recorded failure no longer reproduces.) Governs R2-R8.
- **Fix before closure if the dependency failure reproduces.** (session-settled: user-directed — chosen over reporting without fixing: the user required autonomous resolution of a reproduced failure.) Governs R9.
- **Preserve the shipped direct-install approach.** Commit `399d8e0` resolved the issue through source-tree installation; caching and a stub validator do not affect correctness evidence for this closure. Governs R5-R6.

### Acceptance Examples

- AE1. **Covers R1-R8.** Given current source contains the dependency setup and current default-branch evidence passes both operating-system jobs, when the issue is closed through the repository issue command-line interface, then implementation changes only the structured issue record and the shipping diff also carries this plan artifact.
- AE2. **Covers R8-R9.** Given a pull request check reports `bun: command not found` or a missing `node_modules/.bin/smithers`, when delivery reaches verification, then the pull request remains unmerged and the issue closure does not reach the default branch.

### Scope Boundaries

- The active change closes `docs/issues/2026-08-18-022-install-smithers-dependencies-in-github-ci.md` with current evidence.
- The active change does not revise the dependency setup that is already present in `.github/workflows/test-dotfiles.yml` unless a pull request check reproduces the original dependency signature under R9.
- The active change does not add caching, redirect tests to the deployed runtime, or replace Smithers with a stub validator.
- Any unrelated GitHub Actions failure remains outside this issue unless it reproduces the recorded dependency signature.

## Planning Contract

### Assumptions

- Default-branch run `32504078129` is sufficient current evidence at plan time because both operating-system jobs executed and passed the deterministic binary preflight plus downstream tests. Execution must replace or supplement it if the default branch advances.
- A documentation-only closure is the minimum correct scope while the source and GitHub evidence remain unchanged.

### Key Technical Decisions

- KTD1. **Use a closure-only diff.** Current `origin/main` at `db9cb20` contains commit `399d8e0`, and GitHub Actions run `32504078129` passed the exact steps that previously failed. (session-settled: user-directed — chosen over implementing an unnecessary fix: the user required closure when reproduction fails.) Governs R2-R5.
- KTD2. **Use the structured issue lifecycle interface.** `scripts/issues` enforces the required `open` to `in-progress` to `done` transition and adds the terminal metadata and Resolution section. Governs R4-R7.
- KTD3. **Keep all changes and shipping in the isolated worktree.** (session-settled: user-directed — chosen over modifying the primary checkout: the user explicitly required isolation.) Governs R8.
- KTD4. **Use step-level GitHub Actions evidence, not the overall run conclusion alone.** The preflight and downstream steps prove both required Smithers directories were usable; this follows the coverage-honesty principle in `docs/solutions/design-patterns/skip-set-parity-proves-reduced-dependencies.md`. Governs R2, R5, and R8.
- KTD5. **Require evidence from the current default-branch tip.** If run `32504078129` no longer targets the default-branch tip, use a newer completed run for that tip or trigger a fresh `workflow_dispatch` run before closing. Governs R2, R5, and R9.

### Sequencing

The executor first rechecks the issue and current evidence.
The executor then performs both required issue lifecycle transitions in one working-tree change, validates the corpus, and ships the closure through the LFG pull request tail.
The pull request checks are the final regression gate before merge.

## Implementation Units

### U1. Close the resolved Smithers CI dependency issue

- **Goal:** Convert the open issue into a validated terminal record whose resolution cites current source and GitHub Actions evidence.
- **Requirements:** R1-R9; AE1-AE2; KTD1-KTD5.
- **Dependencies:** None.
- **Files:**
  - `docs/issues/2026-08-18-022-install-smithers-dependencies-in-github-ci.md`
  - `docs/plans/2026-08-21-1851-fix-close-smithers-ci-issue-plan.md`
- **Approach:**
  1. Re-read the authoritative JSON issue record and confirm that it is still `open` with the recorded dependency signature.
  2. Confirm that `.github/workflows/test-dotfiles.yml` still installs Bun, runs `bun install --frozen-lockfile` in the source-tree Smithers directory, and verifies both Smithers binaries before post-apply tests.
  3. Confirm that default-branch run `32504078129` still targets the default-branch tip and that the Ubuntu and macOS dependency, preflight, and post-apply test steps succeeded. If the branch advanced, require a newer passing run for the current tip or trigger a fresh `workflow_dispatch` run.
  4. Use `python3 scripts/issues start` and `python3 scripts/issues close` for issue `2026-08-18-022`; write a concise Resolution that cites the fixing commit, current green run evidence, both operating-system jobs, and the disposition of all three original open decisions.
  5. Keep the implementation change limited to the issue record. Preserve this plan artifact as the reviewed shipping authority unless the original failure signature reappears.
- **Execution note:** This is evidence-backed repository maintenance; prefer source inspection, structured issue validation, and GitHub Actions verification over new implementation coverage.
- **Patterns to follow:**
  - `scripts/issues` for lifecycle transitions and terminal record formatting.
  - `docs/issues/2026-08-14-004-se-flow-stalls-after-staging-and-epilog-gaps.md` for an evidence-based Resolution when execution, rather than a new code change, closes an issue.
  - `.github/workflows/test-dotfiles.yml` for the existing dependency and preflight contract.
- **Test scenarios:**
  - Given the issue is open, when the repository issue command-line interface performs the start and close transitions, then JSON output reports `status: done`, includes a `closed` date, and the body includes `## Resolution`.
  - Given the resolution text, when a reviewer reads it without session context, then it identifies the fixing commit, the current successful run, and the successful Ubuntu and macOS proof steps.
  - Given the terminal issue record, when the full issue validator runs, then the issue corpus passes without lifecycle or schema diagnostics.
  - Given the closure-only pull request, when GitHub Actions runs, then `test-ubuntu`, `test-macos`, and `lint` pass and neither operating-system job reports the original dependency signature.
  - Given a pull request check reproduces the original dependency signature, when the LFG pipeline evaluates merge readiness, then the pull request remains unmerged and R9 becomes the active path.
- **Verification:** The structured issue is terminal and valid, the diff contains no production or test changes, and the pull request checks prove the dependency contract still passes on both operating systems.

## Verification Contract

| Gate | Command or evidence | Applicability | Pass signal |
|---|---|---|---|
| Authoritative issue state | `python3 scripts/issues show 2026-08-18-022 --json` | Before and after U1 | Before: `status` is `open`; after: `status` is `done`, `closed` is set, and Resolution is present. |
| Issue corpus | `make test-issues` | After U1 | Strict issue validation and issue command-line interface tests pass. |
| Default-branch currency | `gh run list --workflow 'Test Dotfiles' --branch main --limit 1 --json databaseId,headSha,status,conclusion,url` | During U1 | The latest run targets the current default-branch tip; if it is not complete and green, execution waits for or triggers fresh evidence. |
| Current default-branch proof | `gh run view 32504078129 --json conclusion,headSha,jobs,url` | During U1 when the run remains current | Run commit is `db9cb20`; both operating-system jobs and the named dependency, preflight, and post-apply steps succeeded. |
| Pull request regression gate | GitHub Actions workflow `Test Dotfiles` | After push | `test-ubuntu`, `test-macos`, and `lint` are green; no original dependency signature appears. |

The plan does not call `make test-suite` because it reads the deployed home directory and cannot prove a checkout-only documentation change.
The plan does not call `make test-ubuntu` because no managed, production, or test file changes on the closure-only path; the pull request workflow supplies the cross-platform regression evidence.

## Definition of Done

- Issue `2026-08-18-022` is `done` with a closed date and a self-contained Resolution that cites the fixing commit, current green run evidence, both operating-system jobs, and the disposition of all three original open decisions.
- `make test-issues` passes after the lifecycle mutation.
- The active implementation diff contains no production or test code changes.
- The LFG pipeline opens a pull request from the isolated worktree.
- The pull request's `test-ubuntu`, `test-macos`, and `lint` jobs pass before merge.
- The issue closure reaches the default branch only through the merged pull request.
- No abandoned fix attempt or unrelated cleanup remains in the diff.

## Appendix

### Sources and Research

- `docs/issues/2026-08-18-022-install-smithers-dependencies-in-github-ci.md` — authoritative failure description and scope.
- `.github/workflows/test-dotfiles.yml` — current Bun setup, frozen source-tree dependency install, both-directory preflight, and post-apply test ordering.
- `home/.chezmoiscripts/run_onchange_after_4-install-smithers-deps.sh.tmpl` — deployed-runtime install behavior that explains why the workflow provisions Bun before apply on Ubuntu.
- `tests/scripts.bats` — checkout-based `se blocks --json` test and its source-tree Smithers dependency guard.
- `scripts/issues` — required lifecycle state machine and terminal issue schema.
- `docs/solutions/design-patterns/skip-set-parity-proves-reduced-dependencies.md` — local learning that a green suite alone does not prove dependency coverage.
- Commit `399d8e0105ef698a2c090fb858ae6a509bf99b51` — the existing dependency fix, reachable from current `origin/main`.
- GitHub Actions run `32504078129` — https://github.com/Seigiard/my-mac-setup/actions/runs/32504078129
- Ubuntu job `96840269094` — https://github.com/Seigiard/my-mac-setup/actions/runs/32504078129/job/96840269094
- macOS job `96840269336` — https://github.com/Seigiard/my-mac-setup/actions/runs/32504078129/job/96840269336
