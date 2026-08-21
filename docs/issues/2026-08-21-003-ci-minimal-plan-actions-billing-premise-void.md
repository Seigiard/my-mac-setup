---
title: "The CI-minimal-brew-install plan justifies itself with Actions billing that a public repo does not pay"
short_description: "The CI-minimal-brew-install plan justifies itself with Actions billing that a public repo does not pay"
type: "bug"
category: "testing-ci"
tags: ["testing-ci","bug"]
date: "2026-08-21"
status: "done"
priority: "low"
parent-plan: "docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md"
closed: "2026-08-21"
---

## Why this exists

`docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md` states in its Problem Frame
(line 33) that CI install time "is billed Actions minutes on every commit". That is false for
this repository.

`Seigiard/my-mac-setup` is public — `gh repo view --json visibility` returns `"PUBLIC"`.
GitHub does not meter standard GitHub-hosted runners on public repositories, and that covers
both `ubuntu-latest` and `macos-latest` as used in `.github/workflows/test-dotfiles.yml`. The
10x macOS billing multiplier applies only to private repositories. The plan's install-time
saving is therefore worth zero dollars.

The plan's *other* stated justification survives intact and is the real one: install time is
"the largest single component of the wait between pushing and knowing whether a change is
good". Feedback latency is a genuine payoff; billing is not. Only the billing sentence is
wrong.

Found during the document review of the sibling CI-workflow-hygiene plan
(`docs/plans/2026-08-20-2217-chore-ci-workflow-hygiene-plan.md`), where the same premise
appeared and has since been corrected in that document.

## Scope

- Remove or correct the "billed Actions minutes on every commit" clause in the CI-minimal
  plan's Problem Frame, keeping the feedback-latency justification that already stands beside
  it.
- Confirm no downstream section of that plan sizes its targets against a cost figure rather
  than a time figure. Its Objective and stop condition (line 20) read as time-based, so this
  is expected to be a one-clause edit, not a re-plan.

Checked and **not** affected:

- `docs/plans/2026-08-20-2217-perf-docker-baked-brewfile-plan.md` — targets repeated local
  `make test-ubuntu` runs, not CI billing.
- `docs/plans/2026-08-20-2217-perf-parallel-bats-suite-plan.md` — targets suite wall time and
  makes no Actions-billing claim.

## Open decisions

- If this repository ever becomes private, the cost framing becomes real and macOS runners
  bill at a 10x multiplier. Is private visibility a plausible future state worth planning
  around, or should every CI plan's objective be permanently written around latency alone?

## Resolution

Fixed 2026-08-21 during the document review of the CI-minimal-brew-install plan. Verified the
premise independently first: `gh repo view --json visibility` returns `"PUBLIC"`.

The Problem Frame's billing clause is gone. It now reads that feedback latency is the whole
payoff, states explicitly that GitHub does not meter this repository's standard runners, and
says that any framing of the work as a cost reduction is wrong.

Confirmed the rest of the plan sizes nothing against cost: the Objective and the stop
conditions are stated in time, and a new first unit measures the Homebrew-only share of the
apply step so the speed target is checked against a brew-only number rather than a whole-step
wall clock.

The open decision about future private visibility is not carried forward. If the repository
ever goes private, the cost framing becomes real and macOS runners bill at a 10x multiplier —
that is a new decision to make then, not a gap in this plan.

Not yet committed; no commit sha.
