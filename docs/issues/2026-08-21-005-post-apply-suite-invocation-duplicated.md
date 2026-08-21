---
title: The post-apply suite invocation is duplicated across five sites and drift degrades silently to sequential
type: follow-up
date: 2026-08-21
status: open
parent-plan: docs/plans/2026-08-20-2217-perf-parallel-bats-suite-plan.md
---

## Why this exists

The list of five post-apply bats files, plus the flags that make the run parallel, is
written out separately in every place the suite runs. Today that is four sites; the
parallel-bats plan adds a fifth:

- `.github/workflows/test-dotfiles.yml` — the `Run post-apply tests` step in the
  `test-ubuntu` job
- `.github/workflows/test-dotfiles.yml` — the same step in the `test-macos` job
- `docker/docker-compose.yml` — the `test-full` service `command`
- `docker/docker-compose.yml` — the `test-quick` service `command`
- `Makefile` — the `test-suite` target the parallel-bats plan's U3 adds

The failure mode is that a missed site does not fail. Drop `--jobs` from one of them and
that runtime silently reverts to sequential execution; add a sixth `.bats` file and
whichever site was forgotten silently stops testing it. Both are green-CI outcomes, so
nothing surfaces them. The duplication predates the parallel-bats plan — the file list was
already repeated four times — but that plan widens it, because the flags now carry
behaviour rather than just naming inputs.

## Scope

Give the invocation one definition and have every site call it. Options worth weighing:

- A `Makefile` variable holding the file list and the flags, with the workflow and compose
  services invoking `make` rather than `bats` directly. Keeps one file authoritative;
  couples CI to the Makefile.
- A small `tests/run-post-apply.sh` wrapper that every site calls. Neutral to the caller;
  adds a script to shellcheck's surface.
- A guard test in `tests/smoke.bats` asserting that the file list in the workflow, the two
  compose commands, and the Makefile agree. Leaves the duplication but makes drift red.

## Open decisions

- Which of the three approaches? The wrapper script is the least coupled, but this repo
  already routes local test entry points through the `Makefile`.
- Should the guard test be added regardless of which approach wins, as defence against a
  future sixth site?

## Update 2026-08-21: the fifth site now exists

`docs/plans/2026-08-20-2217-perf-parallel-bats-suite-plan.md` landed, so this is
no longer a prediction. The invocation is now written out five times, and four of
them carry behaviour rather than just a file list:

- `.github/workflows/test-dotfiles.yml`, `test-ubuntu` -- `bats --jobs 8 --no-parallelize-across-files <5 files>`
- `.github/workflows/test-dotfiles.yml`, `test-macos` -- same
- `docker/docker-compose.yml`, `test-full` -- same
- `docker/docker-compose.yml`, `test-quick` -- same
- `Makefile`, `test-suite` -- same flags over **four** files, not five

That last one is a deliberate difference, not drift: the local target omits
`tests/idempotent.bats` because it runs `chezmoi apply` with no `--destination`
and would deploy the checkout over the developer's live dotfiles
(`docs/issues/2026-08-21-004`). Any single-definition fix has to keep the
host-safe subset expressible, so a plain shared constant is not sufficient on its
own -- it needs the file list and the host-safe file list as two names.

The drift risk named above is now concrete: dropping `--jobs 8` from any one site
silently returns that runtime to sequential execution, and nothing goes red.
