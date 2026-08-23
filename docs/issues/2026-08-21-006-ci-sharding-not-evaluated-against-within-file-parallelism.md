---
title: "Sharding the post-apply suite across CI jobs was never evaluated against within-file parallelism"
short_description: "Runner-level sharding would isolate each `$HOME` but repeat the dominant `chezmoi apply`, while `tests/scripts.bats` holds 85% of the Ubuntu baseline and must be split before a file matrix can reduce wall time materially."
type: "idea"
category: "testing-ci"
tags: ["testing-ci","idea"]
date: "2026-08-21"
status: "done"
priority: "low"
parent-plan: "docs/plans/2026-08-20-2217-perf-parallel-bats-suite-plan.md"
closed: "2026-08-23"
---

## Why this exists

The parallel-bats plan chose within-file parallelism (`bats --jobs N
--no-parallelize-across-files`) over cross-file parallelism, and recorded the reason: the
shared `$HOME` that `tests/idempotent.bats` mutates via a real `chezmoi apply` makes
cross-file interleaving unsafe on one machine. That reasoning is sound for one machine, and
the decision is settled.

A third option was never written down: shard the files across separate CI runner VMs via a
GitHub Actions matrix. Each shard gets its own `$HOME`, so the shared-state hazard that
drives the whole approach disappears rather than being worked around — no audit, no
`BATS_NO_PARALLELIZE_WITHIN_FILE` opt-outs, no locking primitive.

It is probably still the weaker option, and that is worth recording too. Two costs stand
out. Each shard repeats the `chezmoi apply` that dominates job setup, so total billed
minutes go up even as wall time falls. And it does nothing for local or Docker runs, which
the within-file approach improves for free. The measured per-file split also makes sharding
awkward: `tests/scripts.bats` is 85% of the Ubuntu baseline, so a per-file matrix produces
one 228 s shard and four shards under 25 s — almost no wall-time gain without also
splitting that file.

Filing it so the option is on record as considered rather than missed, and so the numbers
above do not have to be re-derived if within-file parallelism under-delivers.

## Scope

Revisit only if the parallel-bats plan's *stable but slow* stop condition fires — that is,
the suite is green but stays above 60% of baseline. At that point compare three paths:

- Cross-file parallelism on one machine (already the plan's named follow-up; needs
  `$HOME`-mutation isolation for `tests/idempotent.bats`)
- Matrix sharding across runners (needs `tests/scripts.bats` split to be worth anything)
- Per-test optimization inside `tests/scripts.bats` (explicitly out of the plan's scope)

## Open decisions

- Is billed CI minutes a real constraint for this repo, or is wall time the only thing that
  matters? The answer decides whether sharding is viable at all.
- Splitting `tests/scripts.bats` into topic files would help sharding *and* cross-file
  parallelism. Is that refactor worth doing on its own merits, independent of speed?

## Resolution

Carried the runner-level matrix sharding comparison into
`docs/issues/2026-08-21-012-macos-suite-misses-the-60-percent-wall-time-gate.md`,
the active stable-but-slow residual issue. The residual now records why sharding
avoids shared-home interleaving but remains lower priority: every shard repeats
the dominant `chezmoi apply` setup, local and Docker runs do not improve, and
`tests/scripts.bats` must be split before a file matrix can reduce wall time
materially.
