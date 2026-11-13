---
name: code-review
description: Default code review and pre-PR review. Choose the review route, delegate confirmed fixes to fresh tdd chain children, and repeat after fixes. Use when asked to review code, a diff, a branch, or a PR.
argument-hint: "[scope | PR URL/number | base:<ref>] [plan:<path>] [--profile <name>] [mode:agent]"
---

# Code review loop

Settle the route in step 1 before loading the `revmux` or `hc` skill. On the revmux
route, use the `revmux` skill for scope resolution and the first round; use the preparation
and collection procedure in step 2 for follow-up rounds and report summaries. This skill owns
the apply and repeat policy below; it replaces revmux's interactive fix choice and its stock
`references/loop.md` policy.

When already acting as a reviewer inside revmux or another report-only review job, follow
that job's supplied rubric and return findings directly.

## 1. Establish the review scope

Resolve the user's scope through the applicable review route. Record the checkout, fixed base
commit, paths, explicit exclusions, and initial working-tree state. Include the in-scope committed,
staged, unstaged, and untracked work. List untracked files for reviewers to read because
git diff omits them. Every later round covers this same cumulative scope plus its fixes,
against the same base; the base is not reset to the commit at which the loop started.

Reuse the caller's run directory when one is supplied. Otherwise create
`~/.claude/artifacts/review-<task-id>/` in the first round. Create the directory only.
Use this directory for every round's report and verdict files, and for the tdd chain when
delegation starts.

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
  the surface already examined. The surface is the set of public functions, options,
  commands, file formats, dependencies, and modules the earlier rounds read. Handling
  another input in an existing function, a new test for it, and a contained documentation
  fix all stay within that surface.
- Use the starting profile when a fix adds to the surface. Restore it even when the
  preceding round was `final`.
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
- On the revmux route, the caller prepares round 1 with the `revmux` skill and prepares every
  later round by running

  ```
  <this skill's directory>/scripts/revmux-round.sh next --task <id> --base <fixed base sha> \
    --profile <selected profile> --out-dir <run-dir> --exclude "<exclusion>" \
    --context-file <evidence file> --note "<what changed since the previous round>" --wait
  ```

  Add `--workdir <worktree>` for a fetched PR. When the follow-up targets only part of the cumulative
  change, add one repeatable `--only <pathspec>` per part to review. Collect the round's report,
  progress log, and terminal status from `<run-dir>/<run>.json`, `.log`, and `.exit`.

  When a round reviews values that do not live in Git, such as artifact checksums, digests, or
  version strings, write them as a flat JSON object and pass `--candidate <file>` instead of
  putting them in `--note`. Candidate keys must match `[A-Za-z0-9_.-]+`; values must be non-empty,
  single-line strings. The rendered Candidate section counts toward the 1500-character scope
  limit. Use `--note` for prose about what changed since the previous round.

Reuse the task ID and create a new round each time. Carry the original goal and every exclusion
recorded so far forward; on the revmux route that is one `--exclude` per exclusion. Let revmux
inject prior findings and describe the current scope rather than copying old reports into it.
Later rounds reuse the same run directory and its lock and Verdicts.
Pass the caller's report-only constraint to reviewers: inspect the checkout without editing
it or running tests. Reviewers stay report-only; fixes are delegated to fresh `tdd` chain
children and verification stays with the caller.

Include available verification results in the round context, naming their commands and the
state they cover; on the revmux route, write them to the `--context-file` under the same file
name in every round, so it replaces the carried copy. Mark checks without current evidence as
unknown.

On the revmux route, wait for a terminal result under the host's long-running-work rules.
With `--wait`, the command blocks until the `.exit` file exists; run it detached and read
`.exit` afterwards. Keep report JSON and
progress logs separate. `.exit` `0` and `1` are completed reviews; anything else is a tool failure.
A tool or launcher error, malformed output, missing sources, or non-empty
`sources.degraded` means incomplete coverage: report the failure and stop rather than claiming
convergence. For a healthy `raised 0` source, name the source and inspect its `agents/<name>.*`
tee; treat it as incomplete only when the tee shows that the agent could not work.

On the prose route, the fresh child must produce a parseable report with the required keys;
an absent or malformed report is incomplete coverage, so report the failure and stop.

Run `<this skill's directory>/scripts/revmux-round.sh summary <report.json>` and read its output
instead of the full report. Its last line is the severity count. The projection includes source
coverage, findings, open questions, and the
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

### Grade

Grade each finding before writing its verdict. The reviewer's severity is a proposal; the
grade is the caller's. A finding is **reachable** when it names a path the ticket owns, the
ticket being the issue or request the caller named, `plan:<path>` included: an acceptance
criterion, a flow the ticket's description names, an input this project's users produce, or,
for agent-facing text, a run an agent following the text takes. A criterion establishes
reachability through the occurrence `ticket.md` records as its evidence (`tdd`, Before the
chain); a scenario, limit, or guard that no occurrence names is polish, however plausible it
reads. A finding whose input the reviewer built is a **construction**: polish, unless the
ticket or the review context names an occurrence of that input or its class. When the ticket
relaxes a guard, filter, or validator, an input the base blocked and the head allows is the
ticket's intended direction, and a defect only through an occurrence. A
reachable finding keeps the reviewer's severity. Every other finding is **polish** and is
graded `minor`. A **behavior gap** on a reachable path keeps that path's grade; a finding
that asks only for a test, with the code correct, is `minor`.

A **fix round** is a round whose routed findings produced fix commits; the budget is five per
review loop. The loop is in **closeout** once the two latest rounds graded nothing above
`minor`, or once five fix rounds have been verified. In closeout, route no fix: defer every
remaining `minor`, and put a reachable critical or major to the user as a decision brief on
raising the budget.

A reachable finding against the mechanism the previous round's fix changed, when it is not
that round's defect returning, means the mechanism is wrong rather than one instance of it.
Route no fix for it: put narrowing the ticket against redesigning the mechanism to the user
as a decision brief (`~/.claude/shared/decision-brief.md`), with the occurrences each option
keeps and loses.

Write `<run-dir>/review-<round>.md` with one grade, the path that establishes reachability,
and one verdict per finding and open question: `test`, `code`, `decision`, `defer`, or
`reject` with the reason, using the eligibility rules below.

Confirm the in-scope tree still matches what was reviewed. If it changed during the
round, review the new state before routing stale findings. Report the round's findings
and the `good-css` results briefly, then act without another approval prompt:

- Fix a reachable `critical` or `major` in the agreed scope through fresh `tdd` chain children.
- Fix a reachable `minor` through a fresh child when its defect and remedy are clear, the edit
  is one local, reversible change, and it needs no product decision, design choice, or taste
  judgment.
- Defer every other `minor`, polish included: one line each in the review file, with the
  reviewer's title and the reason. Deferred findings go into the final report under step 5;
  the PR body's "Watch out for" section lists them as deliberate omissions, and the ticket's
  closing comment names them, from there.
- Use `confirmed` and `refined` findings as candidates, checking each against the current
  source. Establish an `unverified` finding yourself before acting on it.
- Keep false positives, disputed fixes, and decisions out of the apply batch and explain
  why. Keep `pre_existing` and `immaterial` separate.

Before the first delegation, run `tdd`'s "Before the chain" in the run directory when it has no
`ticket.md`; this performs the clean-tree check and defines the review scope and goal.

Fix the mechanism, including matching in-scope occurrences, rather than only the quoted
example. Each round's routed findings form one `tdd` batch: run `tdd` steps 1-2 for them in the
existing run directory, reusing the fields an earlier batch recorded when they are unchanged,
then enter through `tdd`'s "Entering mid-chain" section. Copy every literal in a routed
criterion, such as an expected string, escape, or number, from the finding's body or from a
tool's output. When a later round shows a routed criterion wrong, correct it in `ticket.md`
and note the correction in that round's review file; a second correction of the same
criterion is a decision. A **behavior gap** or a **suspect
test** gets a test writer; every other supported finding is **code-only** and goes to one
implementer against the existing lock, or checks-only when there is none. `tdd` owns the child
modes, tiers, calibration, turn budget, and the response to a failure.

Children commit fixes on the reviewed branch. Pushes and PR
creation follow the two-way-door rule in the global `CLAUDE.md`. Editing a fetched PR or running under `mode:agent`
follows the report-only rules in step 1.

When no child can start, report the reason and stop. The caller never writes a fix itself.

The caller verifies the result through the complete `tdd` step 5, including any planned test
calibration, on `tdd`'s evidence rules: a child's verdict is not evidence, its logs are. The
caller still checks styling in code-review's own step 3.

## 5. Repeat or finish

Apply these rules in order:

1. If checks fail or coverage is incomplete, stop as blocked.
2. If this round produced fix commits and caller verification passed, return to step 2. This
   includes minor-only fixes and edits to docs, prompts, or skills: every fix gets a
   confirming round, even when another finding still needs a decision.
3. Otherwise finish: this complete round routed no fix. An unresolved reachable critical or
   major, a closeout decision included, leaves the review blocked; skipping it does not make
   the review clean. Report deferred findings and open decisions as remaining work, not as an
   empty findings list.

If the same defect returns after its attempted fix, diagnose the failed remedy before routing it
again. Repeated fixes that make no progress need a decision and remain blocked; they are not a
reason to silently lower the review bar.

Report the task and rounds, actual profile and source coverage, applied fixes, check
results, deferred findings, remaining findings and decisions, commit status, and why the loop
stopped.
Use revmux's finding tags and report format, with a decision question only when one remains.
