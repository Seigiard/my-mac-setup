---
title: make test-ubuntu labeling drift — runs test-quick, docs say "Full test"
type: chore
date: 2026-08-20
status: open
---

## Why this exists

Two labels contradict what `make test-ubuntu` actually runs, and both mislead a reader choosing a test target:

- `CLAUDE.md` describes `make test-ubuntu` as "Full test in Docker", but `Makefile:24-25` maps it to the compose service `test-quick`, not `test-full`.
- `docker/docker-compose.yml` comments the `test-quick` service as "Quick test (no package installation, just config files)", yet its command runs a full `chezmoi apply`, which triggers `run_onchange_after_1-install-packages.sh` and installs the whole Brewfile.

In practice `test-quick` and `test-full` run the same apply-plus-suite flow; the only difference is `test-full`'s extra echo banners. Surfaced by the doc-review pass on the 2026-08-20 CI-speedup plans (`docs/plans/2026-08-20-2217-*.md`); pre-existing drift, not introduced by those plans.

## Scope

- Decide whether `test-quick` should actually be quick (skip the apply/package step) or whether the two services should merge.
- Align the `CLAUDE.md` table, `Makefile` help text, and compose comments with whatever the services actually do.

## Open decisions

- Merge `test-quick` into `test-full` vs. make `test-quick` genuinely quick. The parallel-bats plan's U4 measures via `make test-ubuntu`, so whichever service it maps to should match CI's apply-then-suite path.
