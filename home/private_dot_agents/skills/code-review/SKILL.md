---
name: code-review
description: Default code review and pre-PR review. Choose the review route, delegate confirmed fixes to fresh tdd chain children, and repeat after fixes. Use when asked to review code, a diff, a branch, or a PR.
argument-hint: "[scope | PR URL/number | base:<ref>] [plan:<path>] [--profile <name>] [mode:agent]"
---

# Code review loop

Use the route in step 1 for scope resolution, round preparation, review execution, and
report interpretation. Settle the route in step 1 before loading the `revmux` or `herdr`
skill. On the revmux route, use the `revmux` skill for those operations.
This skill owns the apply and repeat policy below; it replaces revmux's interactive fix
choice and its stock `references/loop.md` policy.

When already acting as a reviewer inside revmux or another report-only review job, follow
that job's supplied rubric and return findings directly. Do not launch a nested review.

## 1. Establish the review scope

Resolve the user's scope through the applicable review route. Record the checkout, fixed base
commit, paths, explicit exclusions, and initial working-tree state. Include the in-scope committed,
staged, unstaged, and untracked work. List untracked files for reviewers to read because
git diff omits them. Every later round covers this same cumulative scope plus its fixes,
against the same base; the base is not reset to the commit at which the loop started.

Reuse the caller's run directory when one is supplied. Otherwise create
`~/.claude/artifacts/review-<task-id>/` in the first round. Create the directory only;
the clean-tree requirement belongs to step 4. Use this directory for every round's
report and verdict files, and for the tdd chain when delegation starts.

Resolve an explicit `base:<ref>` to a full commit SHA once and use it for every round.
Treat `plan:<path>` as goal context, not a path filter on the reviewed changes.

Preserve existing user edits. Apply only to the local checkout being reviewed. A fetched
PR in a temporary worktree is report-only unless the user explicitly authorizes editing
that branch. `mode:agent` also requests one report-only round, with no apply loop.

Name the project's gates: lint, types, tests, and CI jobs. Ask what part of the diff no gate
verifies. When nothing is left, take the no-review route.

Decide the review route once per round from `git diff --name-status -M100% -C100% <base>` plus
untracked files:

- If every entry is `R100` or `C100` and each path keeps its meaning to the tools that read it
  (including chezmoi prefixes, suffixes, significant parent directories, and skill names), skip
  review. The final report, and the PR when there is one, state why. A rename that changes such
  meaning takes the revmux route.
- If every changed path is agent-facing text, use the prose route. This includes skills and their
  reference files, `AGENTS.md`, `CLAUDE.md`, agent rules and shared instruction docs. A `.tmpl`
  file counts as a template.
- Otherwise use the revmux route, including any script, template, config, or test, alone or mixed
  with prose.

Read `revmux config` and record the resolved default profile. On the revmux route, the
starting profile is that default, with `--profile` omitted, unless the user names another or
the gap is small and nameable. For a small gap, take the narrowest profile whose `description`
covers it; the length of its `roster` is its cost. When the gap is broad or unclear, keep the
default. Go wider than the default only when the user names the profile. State the profile and
the reason before launch. A user-selected profile stays in effect across rounds unless the user
authorizes a change.

## 2. Run one review round

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

Choose the route before preparing the round:

- On the no-review route, end the loop and state the reason: the gates that cover the diff,
  or that the changes are verbatim moves, copies, or pure renames.
- On the prose route, skip revmux preparation and launch. Dispatch one fresh prose child as
  described below.
- On the revmux route, follow the `revmux` skill's round preparation and launch procedure.

Reuse the task ID and create a new round each time. Carry the original goal and exclusions
forward. On the revmux route, let revmux inject prior findings and describe the current
scope rather than copying old reports into it. Later rounds reuse the same run directory
and its lock and Verdicts.
Pass the caller's report-only constraint to reviewers: inspect the checkout without editing
it or running tests. Reviewers stay report-only; fixes are delegated to fresh `tdd` chain
children and verification stays with the caller.

Include available verification results in the round context, naming their commands and the
state they cover. Mark checks without current evidence as unknown.

On the revmux route, wait for a terminal result under the host's long-running-work rules.
Keep report JSON and progress logs separate. Exit `0` and `1` are completed reviews; `1`
is findings, not a tool failure. A tool or launcher error, malformed output, missing
sources, or non-empty `sources.degraded` means incomplete coverage: report the failure and
stop rather than claiming convergence. For a healthy `raised 0` source, name the source
and inspect its `agents/<name>.*` tee; treat it as incomplete only when the tee shows that
the agent could not work.

On the prose route, the fresh child must produce a parseable report with the required keys;
an absent or malformed report is incomplete coverage, so report the failure and stop.

Run `jq -r -f <this skill's directory>/projection.jq <report.json>` and read its output instead of
the full report. The projection includes source coverage, findings, open questions, and the
`pre_existing`/`immaterial` counts. Open one finding's full entry, for example
`jq '.findings[] | select(.id == "<id>")' <report.json>`, only when the projection cannot settle
that finding's verdict. In report-only mode, return here; for `mode:agent`, return the
route's report JSON without wrapping it in a CE report or adding prose.

For a prose route, dispatch one fresh child per round using only the tier and launch mode from
the `tdd` skill's Dispatch section, on tier high. Give it its own prompt: pointers to
`prose-review.md`, the checkout, base SHA, changed paths, the source decisions named by the
caller, the original goal, explicit exclusions, paths of earlier prose-review reports, and
`<run-dir>/prose-review-<round>.json`; give it no `Role` or commit instruction.
Use the narrowest posture that can still write the report outside the checkout. Its report uses
the same keys, so the same projection applies. The follow-up profile policy does not apply to
prose rounds; the repeat and stop rules do.

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

Write `<run-dir>/review-<round>.md` with one verdict per finding and open question: `test`,
`code`, `decision`, or `reject` with the reason, using the eligibility rules below.

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

Before delegation, run `tdd`'s "Before the chain" in the run directory when it has no
`ticket.md`; this performs the clean-tree check and defines the review scope and goal. For
this round's routed findings, run `tdd` steps 1-2 in that same directory: apply the oracle
gate, record seams, allowed test paths, test command, and applicable checks. Run these steps
for every round, whether the directory is new or reused. For a code-only route, record
`base_sha`; when `lock.json` exists, use its existing lock for steps 4 and 5, otherwise use
the checks-only path.

Fix the mechanism, including matching in-scope occurrences, rather than only the quoted
example. Follow the repository's test-oracle gate before adding or changing tests. Route a
behavior gap to one fresh test writer, re-lock, then one fresh implementer. Route a code-only
finding to one fresh implementer. Use one child per role per round, never one per finding; enter
through the `tdd` skill's "Entering mid-chain" section and use its roles, tiers, and escalation
ladder. Run the applicable checks after each coherent fix batch. A failed check is a `tdd` step
5 rejection: use its restore and escalation ladder, and report what remains after a failure on
high.

Children commit fixes on the reviewed branch. Before the first delegation, require a clean
worktree; when in-scope work is uncommitted, report the dirty paths and stop. Pushes and PR
creation remain separate requests. A fetched PR in a temporary worktree and `mode:agent` stay
report-only.

When no child can start, report the reason and stop. The caller never writes a fix itself.

The caller verifies the result: when `lock.json` exists, run the `tdd` step 5 lock diff check
against its existing lock; otherwise use the checks-only validation. Then run the green test
command, applicable checks from repository verification rules, and the clean-worktree check. A
child's report is not evidence. The caller still checks styling in step 3.

## 5. Repeat or finish

Apply these rules in order:

1. If checks fail or coverage is incomplete, stop as blocked.
2. If this round produced fix commits and caller verification passed, return to step 2. This
   includes minor-only fixes and edits to docs, prompts, or skills: every fix gets a
   confirming round, even when another finding still needs a decision.
3. Otherwise finish: this complete round needs no further eligible fixes. Unresolved
   critical or major findings leave the review blocked. Report ambiguous minors and
   open decisions as remaining work, not as an empty findings list.

If the same defect returns after its attempted fix, diagnose the failed remedy before routing it
again. Repeated fixes that make no progress need a decision and remain blocked; they are not a
reason to silently lower the review bar.

Report the task and rounds, actual profile and source coverage, applied fixes, check
results, remaining findings and decisions, commit status, and why the loop stopped.
Use revmux's finding tags and report format, with a decision question only when one remains.
