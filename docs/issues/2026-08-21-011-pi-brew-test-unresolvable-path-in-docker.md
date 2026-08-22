---
title: "The Pi brew auto-updater test cannot resolve its import inside Docker, so make test-ubuntu is red"
short_description: "The focused Pi updater test now imports its subject through the cross-environment SOURCE_ROOT, so case 72 passes in Docker and direct checkout runs."
type: "bug"
category: "testing-ci"
tags: ["testing-ci","bug"]
date: "2026-08-21"
status: "done"
priority: "high"
closed: "2026-08-22"
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

## Resolution

Changed the runtime module load to resolve through SOURCE_ROOT with a direct-checkout fallback. Verified 13 focused Bun tests and the filtered Docker Bats case; the full Docker suite reaches and passes this case but remains red on the separately tracked focus-notify py_compile failure.
