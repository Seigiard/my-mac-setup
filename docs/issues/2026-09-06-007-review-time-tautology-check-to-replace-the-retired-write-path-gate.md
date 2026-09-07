---
title: "Review-time tautology check to replace the retired write-path gate"
short_description: "se-code-review already carries a positive-form tautology criterion (home/private_dot_agents/skills/se-code-review/SKILL.md:46-53, from #147), but only reaches a peer when the conditional upstream testing persona is selected; the outstanding work is un-gating it, making it reason from diff provenance, restoring the negative-assertion case the retired test-oracle-guard used to block, and recording that a one-branch diff cannot judge values originating outside it."
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
gives a policy a five-field `EventPayload` (`filePath`, `content`, `command`, `query`, `url`), of which
a write or edit event carries only `filePath` and `content` — never the rest of the tree. Its
`Policy.evaluate` contract is documented `Pure, synchronous, bounded — no I/O (KTD7)`
(`home/dot_local/lib/agent-hooks/types.ts:61-62`). Reading the working tree or shelling to `git diff`
breaks that contract, and worse, makes the verdict depend on when the author last committed: in this
repository, which commits per unit of work, the same edit would flag or clear on commit timing alone.

So the policy was retired rather than extended, and the class moved to where the whole diff is already
available: the review pass. This record owns the replacement.

## What already exists (verified 2026-09-07)

The original framing of this record — that the review side is empty and a reviewer must be built —
is wrong, and the correction narrows the work substantially.

`home/private_dot_agents/skills/se-code-review/SKILL.md:46-53` already carries a tautology criterion,
added by commit `95bf869` (#147), before this record was filed. It is appended verbatim to both peer
prompts inside the shared review contract, and it targets the **positive** form this record described
as unreached:

> "Tautological tests considered harmful. Flag tests that merely mirror newly added source, prompt,
> config, or fixture text and would stay green while the intended behavior is broken. …"

`home/private_dot_agents/skills/se-code-review/SKILL.md:103` adds an apply-time oracle gate on findings
that request new tests, advisory when the oracle line cannot be completed.
`home/private_dot_agents/skills/se-orchestrator/SKILL.md:91` carries the same rule.

The remaining gap is the conditional: the criterion reaches a peer only **when the upstream `testing`
persona is selected**. That persona is conditional in the upstream catalog — selected when the diff
touches test files or test infrastructure, or when behavior changed without test work. A diff that
changes tests can therefore run a full review with the criterion never dispatched.

Two facts about ownership, both confirmed: no copy of `ce-code-review` exists under `home/` — it comes
from `EveryInc/compound-engineering-plugin` (`home/private_dot_config/agent-skills/manifest:1`) — and
its persona catalog lives upstream at `~/.agents/skills/ce-code-review/references/personas`. The local
wrapper's only lever over persona behavior is appended prompt text. It cannot add a persona.

Between the gate's removal and this record's completion, the class is unenforced by machine in both
directions: `home/dot_local/lib/agent-hooks/policies/index.ts:15-19` registers exactly
`fff-grep-guard`, `webfetch-markdown-hint` and `zsh-reserved-name-guard`, none of which inspects
write or edit content. That gap is accepted and deliberate, not an accident.

## Scope

The reviewer exists; the outstanding work is four deltas against `SKILL.md:46-53`.

- Lift the criterion out of its `When the testing persona is selected` conditional and into the
  unconditional part of the shared review contract, so a diff that touches tests cannot skip it.
- Instruct the reviewer to state, for each added or changed test, where the expected value comes from,
  and to flag it when the answer is a file the same patch changed. Today the criterion asks the peer to
  spot mirroring; it does not ask it to reason from the diff's provenance.
- Restore the negative-assertion form — `assert_not_contains`, `refute_match`, `! grep` without a named
  independent oracle — as one case among several. It regressed to unenforced when `test-oracle-guard`
  was removed, and the current criterion does not name it.
- Record what the check cannot see. A reviewer reading one branch's diff cannot judge a value that
  originates outside it; say so in the criterion rather than implying full coverage.

Keep the criterion advisory. The retired gate failed open by design
(`docs/solutions/design-patterns/gate-bias-follows-blast-radius.md:74-84`); a review finding an author
can overrule with a stated reason preserves that bias.

## Open decisions

- **Distinct persona or added criterion — settled on evidence: added criterion.** The wrapper cannot
  add a persona, because the catalog is upstream-owned; and the two-peer fan-out already produces two
  independent reports, so the independence argument for a separate persona is satisfied at the peer
  level without a third launch.
- **Blocking verdict or reported finding — recommended: reported finding.** `SKILL.md:103` already
  treats an unsatisfiable oracle line as advisory rather than a stop, and
  `gate-bias-follows-blast-radius.md:74` puts a read-only review stage on the fail-open side. Blocking
  here would invert the bias the repository just preserved deliberately by retiring the gate. Not yet
  ratified by the user.

## Known stale reference

`docs/plans/2026-09-04-0737-feat-context-threshold-handoff-plan.md:422` still cites
`home/private_dot_claude/hooks/executable_test-oracle-guard.sh:15-23` as a pattern to follow. That file
is deleted. It is a historical plan document, so the citation is wrong but harmless; noted here so
whoever works this record does not chase it.
