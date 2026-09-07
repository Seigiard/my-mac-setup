---
title: "Review-time tautology check to replace the retired write-path gate"
short_description: "Removing test-oracle-guard left the tautology class unenforced by machine: a reviewer-side check in se-code-review must judge whether a test's expected value came from the same patch, which needs the whole diff the stateless policy core could never see, and it must cover positive assertions rather than only the negative half the retired policy caught."
type: "follow-up"
category: "se-pipeline"
tags: ["tests","code-review","agent-hooks","tautology"]
date: "2026-09-06"
status: "open"
priority: "high"
---

## Why this exists

The repository forbids a tautological test: one whose expected value was copied from the same patch
it claims to protect. Such a test is always green and defends nothing. `CLAUDE.md` states the rule as
prose, and `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md` is the
standard behind it.

Until now a deployed hook policy enforced half of it. `test-oracle-guard` ran on every proposed write
to a test file, across Claude Code, OpenCode and Pi, and blocked *negative* assertions — `assert_not_contains`,
`refute_match`, `! grep` — unless an `oracle:` comment named an independent oracle. It never caught the
positive form, which is the common one: an agent writes `assert_file_contains "$rendered" "new-flag"`
for a flag the same patch introduced, and the gate stayed silent. Confirmed by driving the live
dispatcher: the positive tautology returned `allow`, the negative returned `block`.

The missing half was not an oversight in the policy — it was structural. Deciding whether an expected
value came from the same patch requires the other side of the diff. `home/dot_local/lib/agent-hooks/types.ts`
gives a policy only `filePath` and `content`, and its `Policy.evaluate` contract is documented pure,
synchronous and free of input/output. Reading the working tree or shelling to `git diff` breaks that
contract, and worse, makes the verdict depend on when the author last committed: in this repository,
which commits per unit of work, the same edit would flag or clear on commit timing alone.

So the policy was retired rather than extended, and the class moved to where the whole diff is already
available: the review pass. This record owns the replacement. Between the removal and the replacement
shipping, nothing machine-checks the class in either direction — that gap is accepted and deliberate,
not an accident.

## Scope

- Add a tautology reviewer to `/se-code-review`, whose local content lives in
  `home/private_dot_agents/skills/se-code-review/SKILL.md` and whose peer lifecycle is
  `home/private_dot_claude/shared/herdr-peer-launch.md`. Upstream `ce-code-review` is not owned by
  this repository; the check belongs in the local wrapper.
- The reviewer reads the diff, not a single file. For each added or changed test it must state where
  the expected value comes from, and flag it when the answer is a file the same patch changed.
- Cover the positive form, which the retired policy never reached. The negative form regresses to
  unenforced when this record is opened and should return as one case among several, not as the
  whole check.
- Keep the reviewer advisory. The retired gate failed open by design
  (`docs/solutions/design-patterns/gate-bias-follows-blast-radius.md`); a review finding an author can
  overrule with a stated reason preserves that bias.
- Record what the check cannot see. A reviewer reading one branch's diff cannot judge a value that
  originates outside it; say so rather than implying full coverage.

## Open decisions

- Whether the reviewer is a distinct persona in the review fan-out or a criterion added to the
  existing personas. A separate persona reports independently and is easier to evaluate; a criterion
  costs no extra peer launch.
- Whether a flagged test blocks the review's verdict or is reported as a finding the author answers.
  Reporting matches the advisory bias the retired gate carried.
