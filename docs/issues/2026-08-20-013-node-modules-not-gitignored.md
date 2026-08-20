---
title: node_modules is not gitignored, so a local bun install dirties the tree
type: chore
date: 2026-08-20
status: open
---

## Why this exists

`.gitignore` lists only `.DS_Store`, `__pycache__`,
`config/fish/fish_variables`, `.idea` and `.worktrees`. It does not cover
`node_modules`.

The smithers workspace at `home/private_dot_claude/dot_smithers` has a
`package.json` and the CI workflow installs it
(`.github/workflows/test-dotfiles.yml:96-97` and `:147-148`, `bun install
--frozen-lockfile`). Anyone who runs the same install locally to get
`tests/scripts.bats` fully green ends up with thousands of untracked files that
`git add -A` would happily stage.

Found while running the full suite locally: `se blocks --json emits the
composable block catalog` (tests/scripts.bats:4815) fails on a fresh checkout
with `se: smithers binary not found`, and the obvious fix for that failure is
the install that dirties the tree.

## Scope

- Add `node_modules/` to `.gitignore`.
- Check whether the same install path needs a `.chezmoiignore` rule so
  `chezmoi apply` does not try to deploy an installed `node_modules`.
- Consider documenting the local `bun install` step in CLAUDE.md next to the
  test commands, since the full suite cannot pass locally without it.

## Open decisions

- Whether the smithers install should be a documented prerequisite for
  `bats tests/scripts.bats`, or whether that test should skip when the binary
  is absent the way other tests skip on a missing `jq`.
