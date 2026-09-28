---
name: code-review
description: Default code review and pre-PR review. Run revmux, fix confirmed critical and major findings plus unambiguous minor findings, and repeat after any fixes. Use when asked to review code, a diff, a branch, or a PR.
argument-hint: "[scope | PR URL/number | base:<ref>] [plan:<path>] [--profile <name>] [mode:agent]"
---

# Code review loop

Use the `revmux` skill for scope resolution, round preparation, preflight, supervised
execution, and report interpretation. This skill owns the apply and repeat policy below;
it replaces revmux's interactive fix choice and its stock `references/loop.md` policy.

When already acting as a reviewer inside revmux or another report-only review job, follow
that job's supplied rubric and return findings directly. Do not launch a nested review.

## 1. Establish the review scope

Resolve the user's scope through `revmux`. Record the checkout, fixed base commit, paths,
explicit exclusions, and initial working-tree state. Include the in-scope committed,
staged, unstaged, and untracked work. List untracked files for reviewers to read because
git diff omits them. Every later round covers this same cumulative scope plus its fixes,
against the same base; the base is not reset to the commit at which the loop started.

Resolve an explicit `base:<ref>` to a full commit SHA once and use it for every round.
Treat `plan:<path>` as goal context, not a path filter on the reviewed changes.

Preserve existing user edits. Apply only to the local checkout being reviewed. A fetched
PR in a temporary worktree is report-only unless the user explicitly authorizes editing
that branch. `mode:agent` also requests one report-only round, with no apply loop.

Read `revmux config` and record the resolved starting profile. Use that default for the
first round, omitting `--profile`, unless the user names another. A user-selected profile
stays in effect across rounds unless the user authorizes a change.

## 2. Run one revmux round

Choose the profile before preparing each round. Use the selection from step 1 for the first
round; apply the follow-up policy below on every return to this step.

### Follow-up profile selection

When the user has not pinned a profile, choose each follow-up profile without an approval
question. This replaces revmux's Step 7 profile-selection question:

- Use `final` when all eligible findings have been addressed and the fixes stayed within
  behavior, contracts, and structure already examined. New tests for those same cases do
  not by themselves widen the review. This also covers contained documentation fixes.
- Use the starting profile when fixes introduce behavior, dependencies, contracts, or
  structure the review has not examined. Restore it even when the preceding round was
  `final`. If the boundary is uncertain, retain the broader coverage.
- A partial or failed review cannot justify narrowing; resolve its missing coverage first.

Announce the selected profile and the reason, then launch. `final` checks fixes and blocking
defects; it does not search for new minors. Carry unresolved findings and decisions forward:
a finding omitted by the narrower profile is not thereby resolved. Report the resulting
coverage explicitly instead of claiming that a final round proves there are no minors.

### Prepare and collect the round

Follow the `revmux` skill's round preparation and launch procedure. Reuse the task ID and
create a new round each time. Carry the original goal and exclusions forward. Let revmux
inject prior findings; describe the current scope rather than copying old reports into it.
Pass the caller's report-only constraint to reviewers: inspect the checkout without editing
it or running tests. The parent owns fixes and their verification.

Include available verification results in the round context, naming their commands and the
state they cover. Mark checks without current evidence as unknown.

Wait for a terminal result under the host's long-running-work rules. Keep report JSON and
progress logs separate. Exit `0` and `1` are completed reviews; `1` is findings, not a tool
failure. A tool or launcher error, malformed output, missing sources, or non-empty
`sources.degraded` means incomplete coverage: report the failure and stop rather than
claiming convergence.

Read the complete report, including `open_questions`, `pre_existing`, and `immaterial`.
In report-only mode, return here; for `mode:agent`, return the revmux JSON without wrapping
it in a CE report or adding prose.

## 3. Fix and verify

Confirm the in-scope tree still matches what was reviewed. If it changed during the
round, review the new state before applying stale findings. Report the round's findings
briefly, then act without another approval prompt:

- Fix supported `critical` and `major` findings in the agreed scope.
- Fix a `minor` when its defect and remedy are clear, the edit is local and reversible,
  and it needs no product decision, design choice, or taste judgment.
- Use `confirmed` and `refined` findings as candidates, checking each against the current
  source. Establish an `unverified` finding yourself before acting on it.
- Keep false positives, disputed fixes, decisions, and ambiguous minors out of the apply
  batch and explain why. Keep `pre_existing` and `immaterial` separate. An unresolved
  critical or major remains a blocker; skipping it does not make the review clean.

Fix the mechanism, including matching in-scope occurrences, rather than only the quoted
example. Follow the repository's test-oracle gate before adding or changing tests. Run
the applicable checks after each coherent fix batch. Resolve failures caused by the fix
or revert only that fix; preserve the original work and report remaining failures.

Leave changes uncommitted unless the user or calling workflow explicitly authorizes a
commit. A dirty tree does not by itself block this loop. Pushes and PR creation remain
separate requests.

## 4. Repeat or finish

Apply these rules in order:

1. If checks fail or coverage is incomplete, stop as blocked.
2. If this round left any new fixes in the tree and verification passed, return to step 2. This
   includes minor-only fixes and edits to docs, prompts, or skills: every fix gets a
   confirming round, even when another finding still needs a decision.
3. Otherwise finish: this complete round needs no further eligible fixes. Unresolved
   critical or major findings leave the review blocked. Report ambiguous minors and
   open decisions as remaining work, not as an empty findings list.

If the same defect returns after its attempted fix, diagnose the failed remedy before
editing again. Repeated fixes that make no progress need a decision and remain blocked;
they are not a reason to silently lower the review bar.

Report the task and rounds, actual profile and source coverage, applied fixes, check
results, remaining findings and decisions, commit status, and why the loop stopped.
Use revmux's finding tags and report format, with a decision question only when one remains.
