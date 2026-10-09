---
name: code-review
description: Default code review and pre-PR review. Run revmux, delegate confirmed fixes to fresh tdd chain children, and repeat after fixes. Use when asked to review code, a diff, a branch, or a PR.
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

Decide the review route once per round from `git diff --name-status -M100% -C100% <base>` plus
untracked files:

- If every entry is `R100` or `C100` (a verbatim move, copy, or pure rename), skip review. The
  final report, and the PR when there is one, state why.
- If every changed path is agent-facing text, use the prose route. This includes skills and their
  reference files, `AGENTS.md`, `CLAUDE.md`, agent rules and shared instruction docs. A `.tmpl`
  file counts as a template.
- Otherwise use the revmux route, including any script, template, config, or test, alone or mixed
  with prose.

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
Reuse the `tdd` run directory when the caller passes one; otherwise create one through the
`tdd` skill's "Before the chain" section, using the revmux task ID as the ticket name and the
review scope and goal as the ticket.
Pass the caller's report-only constraint to reviewers: inspect the checkout without editing
it or running tests. Reviewers stay report-only; fixes are delegated to fresh `tdd` chain
children and verification stays with the caller.

Include available verification results in the round context, naming their commands and the
state they cover. Mark checks without current evidence as unknown.

Wait for a terminal result under the host's long-running-work rules. Keep report JSON and
progress logs separate. Exit `0` and `1` are completed reviews; `1` is findings, not a tool
failure. A tool or launcher error, malformed output, missing sources, or non-empty
`sources.degraded` means incomplete coverage: report the failure and stop rather than
claiming convergence.

Run `jq -r -f <this skill's directory>/projection.jq <report.json>` and read its output instead of
the full report. The projection includes source coverage, findings, open questions, and the
`pre_existing`/`immaterial` counts. Open one finding's full entry, for example
`jq '.findings[] | select(.id == "<id>")' <report.json>`, only when the projection cannot settle
that finding's verdict. A `degraded` or `raised 0` source means incomplete coverage: stop as today.
In report-only mode, return here; for `mode:agent`, return the revmux JSON without wrapping
it in a CE report or adding prose.

For a prose route, dispatch one fresh child per round through the `tdd` skill's Dispatch section
on tier high. Give it pointers only: `prose-review.md`, the checkout, base SHA, changed paths,
the source decisions named by the caller, and `<run-dir>/prose-review-<round>.json`. Its report
uses the same keys, so the same projection applies. The follow-up profile policy does not apply
to prose rounds; the repeat and stop rules do.

## 3. Check styles

Skip this step when the scope adds or changes no styling. Styling means CSS, Tailwind
classes, StyleX, CSS-in-JS, and inline styles, in any file type. Revmux reviewers do not
carry the `good-css` rules, so the parent checks the changed styling itself.

Load the `good-css` skill and read the reference files it names for the declarations in
the diff. Judge every added or changed styling line against the matching entry and the
conditions in its rules. Tag the results `good-css` and treat them like revmux findings
in step 4: a clear, local replacement is a fix; a taste call, or a technique the project's
browsers lack per the entry's `Support:` line, is a decision to report.

When `good-css` is not installed, report that in the final report and continue; the
styling then counts as unchecked.

## 4. Fix and verify

Write `<run-dir>/review-<round>.md` with one verdict per finding and open question: `test` for
a behavior gap where the test-oracle gate warrants coverage, `code` for a code-only fix,
`decision` for a product, design, or taste choice, or `reject` with the reason. Apply the
existing eligibility rules: supported critical and major findings are candidates, while a minor
must be clear, local, reversible, and decision-free; check `confirmed` and `refined` findings
against current source, establish `unverified` yourself, keep `pre_existing` and `immaterial`
separate, and treat unresolved critical or major findings as blockers.

Confirm the in-scope tree still matches what was reviewed. If it changed during the
round, review the new state before routing stale findings. Report the round's findings
and the `good-css` results briefly, then act without another approval prompt:

- Fix supported `critical` and `major` findings in the agreed scope through fresh `tdd` chain
  children.
- Fix a `minor` through a fresh child when its defect and remedy are clear, the edit is local and
  reversible, and it needs no product decision, design choice, or taste judgment.
- Use `confirmed` and `refined` findings as candidates, checking each against the current
  source. Establish an `unverified` finding yourself before acting on it.
- Keep false positives, disputed fixes, decisions, and ambiguous minors out of the apply
  batch and explain why. Keep `pre_existing` and `immaterial` separate. An unresolved
  critical or major remains a blocker; skipping it does not make the review clean.

Fix the mechanism, including matching in-scope occurrences, rather than only the quoted
example. Follow the repository's test-oracle gate before adding or changing tests. Route a
behavior gap to one fresh test writer, re-lock, then one fresh implementer. Route a code-only
finding to one fresh implementer. Use one child per role per round, never one per finding; enter
through the `tdd` skill's "Entering mid-chain" section and use its roles, tiers, and escalation
ladder. Run the applicable checks after each coherent fix batch. Resolve failures caused by the
fix or revert only that fix; preserve the original work and report remaining failures.

Children commit fixes on the reviewed branch. Delegation requires a clean worktree; when
in-scope work is uncommitted, report the dirty paths and stop before delegating. Pushes and PR
creation remain separate requests. A fetched PR in a temporary worktree and `mode:agent` stay
report-only.

When no child can start, report the reason and stop. The caller never writes a fix itself.

The caller verifies the result: run the `tdd` step 5 lock diff check, the green test command,
applicable checks from repository verification rules, and the clean-worktree check. A child's
report is not evidence. The caller still checks styling in step 3; accepted `good-css` results
route like findings.

## 5. Repeat or finish

Apply these rules in order:

1. If checks fail or coverage is incomplete, stop as blocked.
2. If this round left any fix commits in the tree and caller verification passed, return to step 2. This
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
