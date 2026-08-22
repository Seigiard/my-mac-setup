---
title: "Ubuntu push and PR runs bootstrap Linuxbrew for unreachable duplicate tools"
short_description: "Push and pull-request runs spend about 60 seconds bootstrapping Linuxbrew and installing node, bun, and jq, although later steps use runner-provided copies because the Linuxbrew prefix never reaches PATH."
type: "bug"
category: "testing-ci"
tags: ["testing-ci","bug"]
date: "2026-08-21"
status: "done"
priority: "medium"
parent-plan: "docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md"
closed: "2026-08-22"
---

## Why this exists

The CI-minimal plan has changed the size and purpose of the install, but it has not removed the
waste on ordinary Ubuntu runs. Push and pull-request events now render only three formulae:
`node`, `oven-sh/bun/bun`, and `jq`. The `test-ubuntu` job still bootstraps Linuxbrew to install
those formulae even though no later step can resolve them from Linuxbrew.

The current chain is verifiable in push run `32553980667`, job `96985167596`:

1. The workflow selected the minimal render: `no Brewfile change; the minimal install stands`.
2. `home/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl` installed Homebrew,
   `node`, `bun`, and `jq`. Homebrew reported four dependencies because the Brewfile also has the
   `oven-sh/bun` tap.
3. The installer repeated `Warning: /home/linuxbrew/.linuxbrew/bin is not in your PATH.`
4. The script's `brew shellenv` export affected only that script process. The workflow added only
   `$HOME/.local/bin` to `$GITHUB_PATH`, so later steps still could not reach Linuxbrew.
5. The workflow had already installed bun through `oven-sh/setup-bun@v2`. The Ubuntu runner image
   supplied node and jq independently. The post-apply suite had no missing-node, missing-bun, or
   missing-jq skips despite Linuxbrew remaining unreachable.

The `Apply dotfiles` step ran from `05:18:44` to `05:19:49`. Homebrew bootstrap and `brew bundle`
occupied about 60 seconds of that 65-second step. This is smaller than the original 177.9-second
full install, but it remains avoidable work on every ordinary push and pull request.

Full-set runs are different. Scheduled and manually dispatched runs, plus a push or pull request
that changes a Brewfile, intentionally install the complete Brewfile as an installability gate.
Scheduled run `32551513158`, job `96978924101`, installed 39 Brewfile dependencies and completed
successfully. Those binaries also remain outside later steps' PATH, but installation itself is the
assertion, so that work is not dead weight.

## Scope

- Skip the Homebrew bootstrap and `brew bundle` on Linux when the CI-minimal render is selected.
- Keep the current full install for scheduled runs, manual runs, and Brewfile-changing diffs. These
  runs prove that the cross-platform Brewfile still installs.
- Keep macOS behavior separate. The shared `MMS_CI_MINIMAL` switch does not prove that the macOS
  job can skip the same formulae or the Homebrew invocation.
- Do not add Linuxbrew to `$GITHUB_PATH` only to justify the minimal install. The Ubuntu job already
  provisions each required test tool outside Linuxbrew, and the workflow declares push and pull
  requests as the fast path.
- Preserve template-render coverage for both minimal and full Brewfiles in
  `tests/templates.bats`.

The Docker path remains the end-to-end Linux environment where Linuxbrew is on PATH. Its separate
Brewfile-baking work does not remove this GitHub Actions waste.

## Open decisions

- Should the package script branch directly on Linux plus `ci_minimal`, or should the workflow pass
  a dedicated variable that skips package installation? The first option reuses existing state;
  the second makes the workflow policy explicit but adds another switch.
- What assertion should prove that an Ubuntu minimal run did not install Homebrew? A focused log or
  filesystem assertion would prevent the optimization from silently regressing while the suite
  remains green.

## Resolution

Skipped Homebrew bootstrap and brew bundle only for CI-minimal Linux renders, preserved full Linux and all non-Linux package installs, and verified the behavior with focused render tests plus the full Ubuntu Docker suite.
