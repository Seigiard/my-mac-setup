---
title: "The Pi brew auto-updater test cannot resolve its import inside Docker, so make test-ubuntu is red"
short_description: "Docker mounts `tests/` at `/home/testuser/tests` and `home/` at `/home/testuser/dotfiles`, so the test's `../home/...` import failed identically in sequential, parallel, and ten stability runs."
type: "bug"
category: "testing-ci"
tags: ["testing-ci","bug"]
date: "2026-08-21"
status: "open"
priority: "high"
---

## Why this exists

`tests/smoke.bats:859` runs `bun test "$BATS_TEST_DIRNAME/pi-brew-auto-update.test.ts"`.
That test file imports its subject with a path relative to itself
(`tests/pi-brew-auto-update.test.ts:10`):

```ts
} from "../home/dot_pi/agent/extensions/brew-auto-update/index.ts";
```

The import assumes `tests/` and `home/` are siblings. They are in the repo
checkout, and in CI, which runs from the checkout root. They are **not** in
Docker. `docker/docker-compose.yml` mounts the two trees at unrelated paths:

```
- ../home:/home/testuser/dotfiles:ro
- ../tests:/home/testuser/tests:ro
```

So `../home` resolves to `/home/testuser/home`, which does not exist, and the
test fails before it asserts anything:

```
error: Cannot find module '../home/dot_pi/agent/extensions/brew-auto-update/index.ts'
  from '/home/testuser/tests/pi-brew-auto-update.test.ts'
0 pass
```

Observed while repeating the post-apply suite inside the container for
`docs/plans/2026-08-20-2217-perf-parallel-bats-suite-plan.md`. It failed
identically in **every** run -- sequential and parallel, all ten stability
repetitions -- which is what identifies it as a path defect rather than a flake.
It is unrelated to parallelism and predates that work.

The consequence is that `make test-ubuntu` and `make test-docker` are red on
`main` for this test, and have been for as long as the mount layout and the
relative import have disagreed. Anyone reading a red Docker run has one failure
to mentally excuse, which is exactly how a second, real failure gets missed.

### Reconfirmed 2026-08-22 on `5f171c9`, and the predicted second failure is here

Reproduced independently while recording the Docker baseline for
`docs/plans/2026-08-20-2217-perf-docker-baked-brewfile-plan.md`. Two consecutive
`make test-ubuntu` runs from a warm image failed identically, at test position
72 both times, with the same unresolved-module error quoted above. So the defect
survived the 21 commits between `9f539b5` and `5f171c9` untouched.

The paragraph above turned out to be exactly right. That baseline also caught a
**second** failure in both runs:

```
not ok 32 focus-notify plugin compiles and declares no build step or extra backend
not ok 72 Pi brew auto updater focused tests pass
```

It is tracked separately in
`docs/issues/2026-08-19-001-make-test-ubuntu-fails-two-tests-on-main.md`. Naming
it here anyway, because the failure this issue describes is the camouflage: a
reader who has learned to excuse one red line excuses two without noticing the
count changed.

Practical consequence for anyone measuring or gating on Docker runs today: a
green `make test-ubuntu` is not reachable, so the usable gate is **exactly these
two failures and no others** — assert the count, not the colour.

## Scope

- `tests/pi-brew-auto-update.test.ts` -- the relative import.
- `docker/docker-compose.yml` -- the two `volumes` entries, if the fix is to make
  the trees siblings in the container instead.
- Any other `tests/*.test.ts` reaching into `../home`; check before fixing just
  this one.

Note that `tests/scripts.bats` solved a sibling version of this problem on
2026-08-21 by routing template rendering through `render_install_packages()` and
passing `--source "$SOURCE_ROOT"` explicitly, rather than trusting relative
resolution. The comment above that helper is worth reading first.

## Open decisions

- **Mount the trees as siblings, or make the import path configurable.** Mounting
  `../home` at `/home/testuser/home` as well would fix it with no test change, but
  adds a third mount of the same tree. Resolving the subject through an env var
  the harness sets keeps one mount and makes the dependency explicit.
- **Whether the Docker services should fail loudly on this today.** They already
  do -- the suite exits non-zero -- but nothing distinguishes this known failure
  from a new one, so in practice it is ignored rather than acted on.
