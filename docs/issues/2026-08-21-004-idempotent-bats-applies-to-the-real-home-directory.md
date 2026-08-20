---
title: tests/idempotent.bats runs chezmoi apply against the developer's real home directory
type: bug
date: 2026-08-21
status: open
---

## Why this exists

`tests/idempotent.bats:12-31` runs four chezmoi commands with no destination
override:

```
chezmoi apply --source="$CHEZMOI_SOURCE" --force --verbose
chezmoi apply --source="$CHEZMOI_SOURCE" --force
chezmoi apply --source="$CHEZMOI_SOURCE" --force   # inside the diff test
chezmoi verify --source="$CHEZMOI_SOURCE"
```

`--source` selects where the templates are read from. It does not change where
they are written. Without `--destination`, chezmoi writes to `$HOME`. So running
`bats tests/idempotent.bats` on a workstation deploys the working checkout over
the developer's live dotfiles — `~/.zshenv`, `~/.zshrc`, `~/.config/**`, and
every other managed path, including uncommitted work in progress.

Observed on 2026-08-21: a plain `bats tests/idempotent.bats tests/smoke.bats
tests/platform.bats` on macOS rewrote the live `~/.zshenv` from the checkout
mid-session.

This contradicts the repo's own rule in `CLAUDE.md`, which says never to run
`chezmoi apply` on the host and to use `make test-local` (diff only) or
`make test-ubuntu` instead. The rule holds for a human typing the command and is
silently broken by the test suite. Nothing in the file or in `make` warns about
it, and `bats tests/idempotent.bats` is an obvious thing to type.

The same four tests are correct in CI: `.github/workflows/test-dotfiles.yml:107`
and `:156` run them in a throwaway runner where `$HOME` is disposable.

Every other test in the repo that needs chezmoi state uses `chezmoi_test_init()`
from `tests/helpers/common.bash:63-69`, which pins `--config` and `--config-path`
to `/tmp/chezmoi-test.yaml`. `idempotent.bats` is the only file that bypasses it.

## Scope

In scope:

- `tests/idempotent.bats` — all four tests.
- Whatever guard is chosen has to keep the CI runs at
  `.github/workflows/test-dotfiles.yml:107` and `:156` meaningful; a guard that
  skips the suite everywhere turns idempotency into untested behavior.

Out of scope: the rest of the suite, which already sandboxes correctly.

## Open decisions

1. **Sandbox, or refuse to run.** Passing `--destination "$BATS_TEST_TMPDIR/home"`
   makes the suite safe everywhere and keeps it running locally, but it stops
   exercising apply against a populated home directory, which is where
   idempotency bugs actually show up. The alternative is a guard that skips
   unless a container or CI marker is present (`CI`, `/.dockerenv`), keeping the
   test honest where it runs and inert on a workstation.
2. **Whether `make test-local` should be the documented local entry point** for
   this file, and whether `Makefile` should stop any target from reaching
   `idempotent.bats` outside Docker.
