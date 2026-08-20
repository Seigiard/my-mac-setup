---
title: Landing order across the four same-date performance plans is undecided and they collide
type: follow-up
date: 2026-08-21
status: done
closed: 2026-08-21
parent-plan: docs/plans/2026-08-20-2217-perf-docker-baked-brewfile-plan.md
---

## Why this exists

Four plans dated 2026-08-20-2217 touch the same three files and were written without an
agreed landing order. Two of the collisions are mechanism conflicts, not merge conflicts —
landing in the wrong order breaks the build rather than producing a diff to resolve.

The plans:

- `docs/plans/2026-08-20-2217-perf-docker-baked-brewfile-plan.md` (bake the Brewfile into the image)
- `docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md` (template-guard the Brewfiles behind `MMS_CI_MINIMAL`)
- `docs/plans/2026-08-20-2217-perf-parallel-bats-suite-plan.md` (parallelize the bats suite)
- `docs/plans/2026-08-20-2217-chore-ci-workflow-hygiene-plan.md`

The collisions:

1. **Templated Brewfile cannot be baked.** The CI-minimal plan renames
   `home/private_dot_config/brewfiles/Brewfile` to `Brewfile.tmpl` and wraps entries in
   chezmoi conditionals (`{{ if not (get . "ci_minimal") }}`). The Docker-baked plan's U2
   does `COPY … Brewfile /tmp/Brewfile` followed by `RUN brew bundle --file=/tmp/Brewfile`.
   `brew bundle` parses a Ruby DSL and raises on Go-template syntax, so if the CI-minimal
   plan lands first the image build fails outright. Both plans currently describe this as a
   one-line path update, which understates it: the bake needs a *rendered* Brewfile, which
   today exists only after `chezmoi apply` runs inside the container.

2. ~~**`RUN brew install parallel` above the bake busts the cache.**~~ **Resolved
   2026-08-21 — this collision no longer exists.** A plan review of the parallel-bats plan
   established that GNU parallel is not a dependency of the chosen configuration at all:
   bats shells out to `parallel` only on the cross-file branch, which
   `--no-parallelize-across-files` disables. Within-file parallelism uses bats' own
   semaphore, needing `flock` (Ubuntu, present) or `shlock` (macOS, present). The
   parallel-bats plan's U2 was rewritten to assert that primitive instead of installing
   anything, so it no longer touches `docker/Dockerfile.ubuntu` or
   `home/private_dot_config/brewfiles/Brewfile`.

3. **Same-file, different-key edits in `docker/docker-compose.yml`.** The Docker-baked plan
   changes `build.context` / `build.dockerfile` and the `test-quick` environment block; the
   parallel-bats plan changes the `command` blocks; the CI-minimal plan plumbs
   `MMS_CI_MINIMAL` into service environments. Field-disjoint, but three independently
   scoped plans editing the same three services.

## Scope

Decide and record a landing order for the four plans, then update each plan's Scope
Boundaries to state its position in that order and what it must do about the plan(s) landing
before it. Specifically:

- If the Docker-baked plan lands first, the CI-minimal plan owns adding a render step
  (`chezmoi execute-template`) or otherwise supplying a rendered Brewfile to the image build.
- If the CI-minimal plan lands first, the Docker-baked plan's U2 cannot be implemented as
  written and must add the render step itself, which also widens the `.dockerignore`
  allowlist beyond the brewfiles directory to carry `.chezmoi.yaml.tmpl` and
  `.chezmoitemplates`.
- ~~The parallel-bats plan must either place `RUN brew install parallel` below the bake layer
  or add `parallel` to the Brewfile instead.~~ Void as of 2026-08-21: that plan installs no
  GNU parallel and does not touch the Dockerfile or the Brewfile. Its only remaining overlap
  is `.github/workflows/test-dotfiles.yml` and the `command` blocks in
  `docker/docker-compose.yml`.

## Open decisions

- Which plan lands first? **Partially settled 2026-08-21:** the CI-workflow-hygiene plan's
  KTD5 fixes one pair — the CI-minimal-brew-install plan lands before that plan's Homebrew
  download cache, because CI-minimal cuts push/PR installs to roughly seven packages and so
  removes most of the download volume the cache exists for. The concurrency block in the same
  plan has no ordering dependency and can land immediately. The Docker-baked and parallel-bats
  collisions above remain open.
- ~~Should the Docker bake render the Brewfile through `chezmoi execute-template`
  unconditionally, so ordering stops mattering at the cost of a wider build context?~~
  Answered in the Resolution: yes, and the Docker-baked plan owns it.
- ~~Does `parallel` belong in the cross-platform Brewfile rather than as a standalone
  Dockerfile layer?~~ Answered 2026-08-21: neither. It is not needed anywhere.

## Resolution

Landing order settled 2026-08-21. Only collision 1 was ever live — collision 2 dissolved when
the parallel-bats plan dropped GNU parallel, and collision 3 is field-disjoint and needs a
re-diff, not an order.

**The order:**

1. **CI-workflow-hygiene, U1 only (the `concurrency` block).** No dependency on anything;
   additive YAML, trivially revertible. Land it whenever, including first.
2. **CI-minimal-brew-install** (whole plan). Nothing blocks it: the Docker bake does not exist
   yet, so the `Brewfile` → `Brewfile.tmpl` rename breaks no build. Docker keeps installing the
   full cross-platform Brewfile per run, which is that plan's own R5.
3. **Docker-baked-Brewfile.** It cannot `COPY` a Go-template Brewfile into `brew bundle`, so
   this plan owns the fix: a render step (`chezmoi execute-template`) ahead of the bake, plus
   two more entries in the `.dockerignore` allowlist it is already creating —
   `.chezmoi.yaml.tmpl` and `.chezmoitemplates` must reach the build context.
4. **CI-workflow-hygiene, U2 (the Homebrew download cache).** Measured after step 2, per that
   plan's own KTD5: CI-minimal removes most of the download volume the cache exists for, so
   measuring earlier would size U2 against a baseline about to vanish.

**Parallel-bats is order-free.** After its KTD4 rewrite it touches neither the Dockerfile nor
the Brewfile. Land it at any point; re-diff `.github/workflows/test-dotfiles.yml` against the
hygiene plan's concurrency block and `docker/docker-compose.yml` against the other two.

**Why CI-minimal before Docker-bake**, which was the actual decision:

- The render step belongs to the plan that already owns `.dockerignore` and
  `docker/Dockerfile.ubuntu`. Putting it in the Docker-baked plan adds two lines to a file that
  plan creates anyway; putting it in CI-minimal would drag a plan that touches no Dockerfile
  into owning one.
- The Docker-baked plan accepts losing the per-run cold-install proof and names CI-minimal's
  nightly full-Brewfile run as the thing that covers that loss. So the nightly has to exist
  first, or there is a window with no installability check anywhere.
- It is consistent with the CI-workflow-hygiene plan's KTD5, which is already user-approved.

The reverse order also works mechanically — the Docker bake lands as written, and CI-minimal
then owns the render step — but it inverts the safety dependency and puts Dockerfile work in
the wrong plan.

Each plan's Scope Boundaries now states its position. Not yet committed; no commit sha.
