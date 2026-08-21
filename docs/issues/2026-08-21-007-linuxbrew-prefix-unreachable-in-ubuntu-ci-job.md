---
title: "The test-ubuntu CI job installs 37 brew packages it can never reach, because Linuxbrew's prefix is never put on PATH"
short_description: "The test-ubuntu CI job installs 37 brew packages it can never reach, because Linuxbrew's prefix is never put on PATH"
type: "bug"
category: "testing-ci"
tags: ["testing-ci","bug"]
date: "2026-08-21"
status: "open"
priority: "medium"
parent-plan: "docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md"
---

## Why this exists

The `test-ubuntu` job in `.github/workflows/test-dotfiles.yml` spends **177.9 s** — 82.5% of
its whole `Apply dotfiles` step — running `brew bundle` for 37 formulae, and then no test can
invoke any of them. Every one of those installs is dead weight.

The chain, each link verifiable:

1. Homebrew is **not** preinstalled on the `ubuntu-latest` runner image.
   `home/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl:16-26` therefore
   installs it from scratch on every run, at a further 26.4 s cost.
2. That script puts brew on `PATH` with `eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"`
   at line 24 — but that export lives and dies inside the script's own process.
3. The workflow adds only `$HOME/.local/bin` to `$GITHUB_PATH`
   (`.github/workflows/test-dotfiles.yml:48-49`). Nothing ever adds
   `/home/linuxbrew/.linuxbrew/bin`.
4. The Homebrew installer says so out loud in the job log:
   `Warning: /home/linuxbrew/.linuxbrew/bin is not in your PATH.`
   (run 32429787123, job 96618922151, `Apply dotfiles` step.)
5. The installer's own "Next steps" only offers to append to `~/.bashrc`, which GitHub's
   non-interactive `bash -e {0}` step shell never reads.

Corroboration from the other direction: the ubuntu post-apply run's complete skip list is
`8 × "Not on macOS"`, `1 × "Only relevant on macOS"`, `1 × "internal descriptor probe"`.
There is not one `jq not available`, `bun not available`, `sqlite3 is required`, or
`zsh not installed` skip — because `jq`, `python3`, `git`, `sqlite3`, and `perl` all come from
the runner image, `zsh` and `bats` from apt, `fzf` from the upstream tarball, and `bun` from
`oven-sh/setup-bun@v2`. The suite never needed Linuxbrew on this job.

The workflow already documents one instance of this without generalising it: the comment at
`.github/workflows/test-dotfiles.yml:67-73` explains that the Brewfile's `bun` lands in
Linuxbrew's prefix "which this job never puts on PATH", and adds a `setup-bun` step to work
around it. That is true of all 37 entries, not just `bun`.

## Scope

Two mutually exclusive directions, and they mean opposite things:

- **Treat the install as waste and stop doing it.** The apply on this job would skip
  `brew bundle` entirely, saving 177.9 s plus the 26.4 s Homebrew bootstrap. This makes the
  ubuntu job a config-and-template test rather than an install test, which is arguably what it
  already is.
- **Treat it as a broken environment and fix PATH.** Add
  `/home/linuxbrew/.linuxbrew/bin` to `$GITHUB_PATH` after the apply. This makes the ubuntu job
  genuinely exercise the Brewfile for the first time — and would very likely surface tests that
  have been silently skipping, plus new failures, since no run has ever had these binaries.

Related but separate: the sibling CI-minimal plan
(`docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md`) reduces the install to five
entries on push/PR. That shrinks the waste; it does not resolve which of the two directions
above is correct, and the nightly full run still pays the whole cost.

## Open decisions

- Which direction? They imply different answers to "what is the `test-ubuntu` job for" —
  a fast config gate, or a Linux installability check.
- If PATH is fixed: how much currently-skipped surface does that turn on, and is the job
  prepared to be red while that is sorted out?
- Does the Docker path (`make test-ubuntu`), which *does* put Linuxbrew on PATH
  (`docker/Dockerfile.ubuntu:37`) and does exercise the Brewfile, already cover the
  installability question well enough that the CI job does not need to?
