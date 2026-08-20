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
