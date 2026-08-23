---
title: "The macOS post-apply suite misses the 60% wall-time gate at --jobs 8"
short_description: "At `--jobs 8`, macOS reached 283 seconds or 66.9% of its 423-second baseline, with bats-core's one-second `shlock` polling as the leading unmeasured cause of the 29-second target gap."
type: "follow-up"
category: "testing-ci"
tags: ["testing-ci","follow-up"]
date: "2026-08-21"
status: "done"
priority: "low"
parent-plan: "docs/plans/2026-08-20-2217-perf-parallel-bats-suite-plan.md"
closed: "2026-08-23"
---

## Why this exists

The post-apply bats suite now runs as
`bats --jobs 8 --no-parallelize-across-files` in both CI jobs, in both Docker
compose services, and through `make test-suite`. The target was a wall time at or
below 60% of the sequential baseline on both CI jobs. Ubuntu meets it; macOS does
not.

Measured in CI run `32441162981`, four suite runs per job, all green:

| Job | Sequential control | `--jobs 8` runs | Median | Ratio | 60% target |
|---|---:|---:|---:|---:|---:|
| `test-ubuntu` (4 cores) | 288 s | 167 / 166 / 165 s | 166 s | **57.6%** | met |
| `test-macos` (3 cores) | 423 s | 285 / 277 / 283 s | 283 s | **66.9%** | missed by 6.9 points |

macOS reaches a 1.50x speedup against Ubuntu's 1.73x. In absolute terms the gap
is 29 s: 60% of the 423 s macOS baseline is 254 s, and the suite lands at 283 s.

This is the *stable but slow* outcome the parent plan names in its stop
conditions, not a failure: it explicitly says missing the threshold with a stable
suite must not block, and directs the residual here. Every repetition was green,
so nothing about the shipped configuration is in question.

## Why macOS gains less

**The leading candidate is the locking primitive, not the core count.** bats
picks its semaphore implementation by what the host has, and the two paths are
not equivalent (`libexec/bats-core/semaphore.bash`):

```sh
bats_run_under_flock() {
  flock "$BATS_SEMAPHORE_DIR" "$@"
}

bats_run_under_shlock() {
      local lockfile="$BATS_SEMAPHORE_DIR/shlock.lock"
      while ! shlock -p $$ -f "$lockfile"; do
        sleep 1
      done
      ...
}
```

`flock` blocks in the kernel and wakes the instant the lock frees. `shlock` has
no blocking mode, so bats busy-polls it and **every contended acquisition costs a
full second**. Linux has `flock`; macOS does not and falls back to `shlock`
(KTD4 in the parent plan established exactly this split). The cost therefore
scales with how often slots change hands -- 330 short tests across 8 slots is a
lot of handoffs -- rather than with core count, and it lands only on macOS.

macOS pays a second `sleep 1` besides: the plan's Problem Frame records that
`bats_semaphore_acquire_slot` polls for a free slot on its own one-second sleep.
That one is cross-platform; the `shlock` poll above is not.

This is a mechanism read from the shipped source, not a measurement. What would
settle it: count `shlock` retries, or total time slept in that loop, during one
`--jobs 8` run on the macOS runner.

Two weaker candidates, neither measured:

1. **Fewer cores.** The macOS runner has 3, the Ubuntu runner 4. Eight jobs is a
   2.7x oversubscription there against 2x on Ubuntu. The job count was chosen by
   measurement, but the measurement that chose 8 was not run on a 3-core macOS
   runner -- the curve came from a `--cpus 4` container.
2. **Serial tail inside the file.** `tests/scripts.bats` carries the suite (85% of
   the baseline). If its slowest few tests exceed the mean by enough, they set a
   floor no job count clears, and that floor is a larger share of a slower
   machine's run.

Distinguishing them is one measurement: the per-test wall times of
`tests/scripts.bats` on the macOS runner, sorted descending. If the top few tests
sum to something near 283 s, the tail is the floor and more jobs will not help.

## Scope

- Instrument the `shlock` busy-poll on the macOS runner first -- it is the only
  candidate here with a mechanism read from source, and it is the cheapest to
  confirm or eliminate. If it dominates, the job count is the wrong dial: fewer
  jobs would mean fewer handoffs and could make macOS *faster*, which would also
  explain why 12 jobs measured slower than 8 there.
- Measure a `--jobs` curve on the macOS runner specifically (4, 8, 12), rather
  than reusing the container curve. A separate literal per platform is possible
  but costs the single shared invocation that
  `docs/issues/2026-08-21-005-post-apply-suite-invocation-duplicated.md` already
  tracks as duplicated across five sites -- weigh that before splitting it.
- Measure the per-test wall-time distribution of `tests/scripts.bats` to find out
  whether a serial tail sets the floor.
- Runner-level matrix sharding is the CI-only variant of cross-file
  parallelism. It avoids the shared-`$HOME` hazard because each GitHub Actions
  runner gets a separate home directory, but it repeats the dominant
  `chezmoi apply` setup on every shard, does not help local or Docker runs, and
  has little wall-time upside while `tests/scripts.bats` remains 85% of the
  Ubuntu baseline. Treat it as lower priority than measuring `shlock`, the
  macOS job-count curve, and the per-test distribution inside `tests/scripts.bats`.
  This records the option from
  `docs/issues/2026-08-21-006-ci-sharding-not-evaluated-against-within-file-parallelism.md`
  in the active residual issue.
- Cross-file parallelism is the deferred lever. It was ruled out by decision, not
  by measurement: `tests/idempotent.bats` mutates the shared `$HOME` through a
  real `chezmoi apply` while other files read deployed state from it. Making the
  files independent -- giving the applying tests their own `$HOME` -- is what
  would unlock it. That is a larger change than this issue.

## Open decisions

- This branch chooses the lowest-cost experiment: add a Bats-only `flock` wrapper
  to the macOS CI `PATH` and map Bats' simple `flock <directory> <command...>`
  call to macOS `lockf -k <directory>/.bats-lockf.lock <command...>`. The
  remaining decision is data-dependent: keep the wrapper if the suite wall-time
  improves without new flakes; otherwise install Homebrew `flock`, measure a
  macOS-specific `--jobs` curve, or close this issue as not worth further work.
- If further work resumes, whether CI billed minutes matter. If wall time is the
  only constraint, repeating `chezmoi apply` across runner-level shards may be
  acceptable; if billed minutes matter too, sharding starts at a disadvantage.
- Whether splitting `tests/scripts.bats` into topic files is worth doing on its
  own merits. That split would help both runner-level sharding and same-runner
  cross-file parallelism.

## Resolution

Resolved by PR #66, commit a6dc72e4377cf771889f6b188f9311d40bf25c05. The macOS GitHub Actions job selected the repository's Bats flock wrapper, verified /usr/bin/lockf, and ran the post-apply suite with bats --jobs 8 --no-parallelize-across-files. In run 32619890143, the post-apply tests started at 2026-08-23T05:17:23.945399Z and the last test completed at 2026-08-23T05:21:32.798725Z, about 249 seconds. Against the recorded 423-second macOS sequential baseline, that is about 58.8%, which meets the 60% wall-time gate.
