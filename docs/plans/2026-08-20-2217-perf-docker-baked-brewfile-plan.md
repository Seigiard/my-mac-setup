---
title: Docker-Baked Brewfile - Plan
type: perf
date: 2026-08-20
status: open
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Docker-Baked Brewfile - Plan

## Goal Capsule

- **Objective:** a repeated local `make test-ubuntu` run stops reinstalling the 37 cross-platform Brewfile formulae inside a fresh container; the `brew bundle` portion of the in-container `chezmoi apply` becomes a near-no-op. The removed work is the Brewfile install, measured at 3 min 36 s / 41 installs (counting dependencies) on the CI Ubuntu runner — the only hard number available, and taken on a different machine than the Docker path, so U3 records a local Docker baseline before anything lands and the plan is judged against that. The Oh My Zsh clones, `mise` node install, and fff-mcp install in the same script stay per-run costs, and the bats suite is untouched, so a repeat run drops by roughly the install time and no further.
- **Means:** `COPY` the Brewfile into the Docker image and run `brew bundle` as an image layer (KTD1), which requires widening the compose build context to the repo root (KTD2) behind a file-scoped allowlist (KTD4).
- **Authority:** this plan.
- **Stop conditions:** if any Brewfile formula fails to install during the image build (it should not — the same set installs during today's per-run apply), pin or drop nothing silently: file the failure in `docs/issues/` and hold the bake (keep today's per-run installs) until it is resolved. A `RUN brew bundle` failure fails the whole image build, so there is no per-formula fallback — tolerating it with `|| true` would break R1's guarantee. Note the blast radius this creates: every Make target depends on `build-docker`, so a transient upstream formula outage turns all of them red, where today it fails only the apply step inside an already-built container.

---

## Product Contract

### Summary

Bake the cross-platform Brewfile into `docker/Dockerfile.ubuntu` as a cached layer. Containers start with all formulae present, so the apply's `brew bundle` verifies instead of installs. The layer rebuilds when the Brewfile changes, or when any Dockerfile instruction above it changes (R2).

### Problem Frame

`make test-ubuntu` and `make test-docker` start a fresh container per run. Inside it, `chezmoi apply` triggers `run_onchange_after_1-install-packages.sh`, which runs `brew bundle` against the full cross-platform Brewfile — 37 declared formulae installed from scratch on every invocation, several minutes each time (the same work measured at 3 min 36 s / 41 installs counting dependencies on the CI Ubuntu runner). The Dockerfile already caches the toolchain (chezmoi, bats-core, fzf, bun as separate `brew install` layers) but never receives the Brewfile, because the compose build context is the `docker/` directory and cannot reach `../home`.

### Requirements

- R1. The Docker image contains all formulae from `home/private_dot_config/brewfiles/Brewfile` at build time.
- R2. The baked layer is invalidated by a change to the Brewfile's content, or by a change to any Dockerfile instruction above it, and by nothing else. Edits elsewhere in the repo — including other files inside `home/` — never trigger a reinstall.
- R3. In-container `chezmoi apply` still executes `brew bundle` against the real apply path, but it now verifies rather than installs. From-scratch installability of the Brewfile moves from every Docker run to image-build time (see Scope Boundaries).
- R4. The Docker build context stays small: only `docker/` and `home/private_dot_config/brewfiles/` are sent to the daemon, so the transfer is well under 1 MB and cannot grow when untracked files appear elsewhere in the repo.
- R5. `make test-ubuntu`, `make test-docker`, `make test-templates`, and `make shell-ubuntu` keep working. One caller-visible change: after a Brewfile edit, all four pay a full image rebuild, so `make test-templates` and `make shell-ubuntu` go from seconds to minutes on that first run. R6 measures it.
- R6. A local repeat-run baseline is recorded on the current HEAD before U1 lands, and the same measurement is repeated after U2, so the speedup claim rests on a measured Docker before/after rather than the CI-runner figure.

### Scope Boundaries

- Not in scope: CI — the GitHub workflow does not use Docker; its install time is owned by the CI-minimal-brew-install plan (`docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md`).
- Not in scope: baking `Brewfile.macos` (darwin-only; the container is Linux and the apply's OS branching already skips it).
- Not in scope: baking the other per-run network costs in the same script — the four Oh My Zsh plugin clones, `mise use --global node@lts`, and the fff-mcp curl install. They all write only into the container's `/home/testuser`, which no volume mount overrides, so they are bakeable in principle; they are excluded here to keep this plan to one mechanism and one file each. U3 records their residual cost so a follow-up plan has a number to work from.
- **Accepted loss — per-run cold-install proof.** Today a formula that stops installing upstream (pulled bottle, renamed tap) fails the very next `make test-ubuntu`. After the bake, the install happens once at image-build time and cached runs only verify, so that breakage stays invisible locally until the layer rebuilds. The CI-minimal-brew-install plan introduces a nightly full-Brewfile run that covers this; if that plan does not land, the Docker path has no ongoing installability check.
- **Landing order — this plan is third of four, and it lands after the template rename.** Order settled 2026-08-21 in `docs/issues/2026-08-21-002-perf-plan-landing-order-undecided.md`: CI-workflow-hygiene `concurrency` block, then CI-minimal-brew-install, then this plan, then the CI-workflow-hygiene download cache.

  **This plan owns the render step.** The CI-minimal-brew-install plan renames `Brewfile` to `Brewfile.tmpl` and wraps entries in chezmoi conditionals (`{{ if not (get . "ci_minimal") }}`). `brew bundle` parses a Ruby DSL and raises on that syntax, so `COPY`ing the renamed source and running `brew bundle` on it **fails the image build outright**. Since that plan lands first, U2 cannot be implemented as currently written. Two additions are required and belong here, not upstream:
  - Render before the bake: produce a plain Brewfile with `chezmoi execute-template` (full render, no `ci_minimal` set — KTD5 keeps full-Brewfile fidelity in the container) and `COPY` *that* into the image.
  - Widen the KTD4 `.dockerignore` allowlist so the render has its inputs: `.chezmoi.yaml.tmpl` and `.chezmoitemplates` must reach the build context, alongside the existing `!docker` and `!home/private_dot_config/brewfiles` entries. Keep the narrow form — still no bare `!home` line.

  The ordering rationale is recorded in the issue: the render step belongs to the plan that already owns `.dockerignore` and the Dockerfile, and this plan's own accepted loss below depends on the sibling plan's nightly run already existing.
- Cross-plan file collisions to sequence, not resolve here: the parallel-bats-suite plan (`docs/plans/2026-08-20-2217-perf-parallel-bats-suite-plan.md`) edits the same three services in `docker/docker-compose.yml` (different keys — `command` vs `build`) and adds a `RUN brew install parallel` layer to `docker/Dockerfile.ubuntu`. Where that layer lands relative to the bake matters (R2, U2 step 2).

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Bake `brew bundle` as an image layer, not a named-volume Homebrew cache.** The layer is keyed on the COPY'd Brewfile's content, so invalidation is deterministic and the image is reproducible from the Dockerfile alone; a named volume is host-local mutable state that no build input describes, and it cannot be rebuilt or reasoned about from the repo. Version staleness is *not* the discriminator — KTD3 accepts the same staleness for the layer and resolves it the same way, through R3's apply-time reconcile. Cost accepted: the first build installs 37 formulae once, and every later Brewfile edit re-pays that install in full.
- KTD2. **Widen the compose build context from `docker/` to the repo root.** `docker/docker-compose.yml` currently declares `context: .` (the `docker/` directory), which cannot reach `home/`. Change to `context: ..` with `dockerfile: docker/Dockerfile.ubuntu`. Chosen over staging a copy of the Brewfile into `docker/` from the Makefile: Docker keys `COPY` cache on file content, so a Make-regenerated copy would invalidate on the same condition and cache just as well — the real cost is that anyone invoking `docker compose -f docker/docker-compose.yml build` directly, bypassing Make, would build from a stale or missing staged file, and the staged copy needs its own gitignore entry. The context widening has no equivalent failure mode.
- KTD3. **The baked install ignores lockfile/version pinning — it installs whatever brew resolves at build time, same as today's per-run install.** A container may hold slightly older formula versions than a just-changed Brewfile expects until the layer rebuilds; the in-container apply's `brew bundle` reconciles (R3), preserving today's semantics.
- KTD4. **The `.dockerignore` allowlist admits the brewfiles directory, not all of `home/`.** The build reads exactly one file from `home/`, so the allowlist names that file's directory. Two reasons over the broader `!home` form: `.dockerignore` does not read `.gitignore`, so a broad `!home` would sweep in untracked trees such as `home/private_dot_claude/dot_smithers/node_modules` (created by the `bun install` the repo's own tooling requires, ignored only by a nested `.gitignore`) and any `private_`/`encrypted_` file a later `chezmoi add` drops into the source tree; and the narrow form makes R4 structurally true instead of a size check that a small credential file would pass. Pattern semantics matter here — write the allowlist as `*`, `!docker`, `!home/private_dot_config/brewfiles`, and do **not** add a bare `!home` line: `*` matches only top-level entries and children inherit their parent's state, so `!home` would re-admit the entire tree and defeat the narrowing.
- KTD5. **Keep full-Brewfile fidelity in the container; do not reuse the CI-minimal plan's `MMS_CI_MINIMAL` guard here.** That plan measures the test suite as needing roughly seven formulae and is already plumbing `MMS_CI_MINIMAL` into `docker/docker-compose.yml`; setting it on `test-quick` would cut the apply to that subset with no context widening, no `.dockerignore`, and no Dockerfile change — a strictly cheaper mechanism. It is rejected because the Docker path is this repo's only place where the *full* cross-platform Brewfile is exercised end-to-end on Linux, and the CI-minimal plan's own R5 depends on that staying true while it makes push/PR CI minimal. Baking keeps the fidelity and removes the cost; guarding keeps the cost structure and drops the fidelity. This is the plan's most reversible decision — see Deferred / Open Questions.

### Assumptions

- All 37 cross-platform formulae install cleanly under Linuxbrew in the image build — the same set already installs during every current per-run apply, both in Docker and on the CI Ubuntu runner, and today's apply script runs under `set -e`, so a broken formula already hard-fails there.
- Docker layer cache is available on the machines that run `make test-ubuntu` (the primary host); on a cold cache the first build simply takes the one-time install cost. `make clean` runs `docker compose down --rmi local` plus `docker image prune -f`, which destroys the baked image — the next build re-pays the full install unless BuildKit's build cache survives, which `clean` does not prune today.
- `HOMEBREW_NO_AUTO_UPDATE=1` and `HOMEBREW_NO_INSTALL_CLEANUP=1` reach every service. **Corrected from an earlier draft:** they come from the Dockerfile's image-level `ENV` and are duplicated in the compose `environment:` block for `ubuntu` and `test-full` only — `test-quick`, the service `make test-ubuntu` and `make test-templates` actually run, sets only `CHEZMOI_NAME` and `CHEZMOI_EMAIL`. Behavior is correct today via the image ENV, but the belt-and-braces the assumption claims does not exist for the plan's headline target, so U1 adds it. This matters because without `HOMEBREW_NO_AUTO_UPDATE=1` the apply-time `brew bundle` refreshes Homebrew's formula data against a days-old baked layer and starts upgrading "outdated" formulae, silently reintroducing multi-minute installs.

---

## Implementation Units

### U1. Widen the build context and add `.dockerignore`

- **Goal:** the image build can read the Brewfile while the context stays minimal, and all three services carry the Homebrew guards.
- **Requirements:** R4, groundwork for R1 and R2.
- **Dependencies:** none.
- **Files:** `docker/docker-compose.yml`, `.dockerignore` (new, repo root).
- **Approach:**
  1. In all three compose services (`ubuntu`, `test-full`, `test-quick`), change `build.context` to `..` and add `build.dockerfile: docker/Dockerfile.ubuntu`.
  2. Add `HOMEBREW_NO_AUTO_UPDATE=1` and `HOMEBREW_NO_INSTALL_CLEANUP=1` to the `test-quick` service's `environment:` block, matching `ubuntu` and `test-full` (see the corrected Assumption).
  3. Create a root `.dockerignore` in allowlist style, exactly three active lines: `*`, then `!docker`, then `!home/private_dot_config/brewfiles`. Per KTD4, do not add a bare `!home` line — it would re-admit the whole tree. Comment the file with the reason, since the omission looks like an oversight otherwise.
- **Patterns to follow:** existing compose file structure; volume mounts stay as they are — they resolve against the compose file's directory, not the build context, so `../home` and `../tests` are unaffected by the context change.
- **Test scenarios:** `Test expectation: none — build configuration; U3 owns behavioral proof.`
- **Verification:** `make build-docker` succeeds; the build log's "transferring context" line reports well under 1 MB (the two allowlisted directories total ~16 KB today). `docker compose -f docker/docker-compose.yml config` shows the Homebrew variables on all three services.

### U2. Bake the Brewfile layer into the Dockerfile

- **Goal:** the image contains every cross-platform formula, in one self-cleaning layer, positioned so ordinary Dockerfile edits do not bust it.
- **Requirements:** R1, R2, R3.
- **Dependencies:** U1.
- **Files:** `docker/Dockerfile.ubuntu`.
- **Approach:**
  1. After the existing tool installs, add `COPY --chown=testuser home/private_dot_config/brewfiles/Brewfile /tmp/Brewfile` followed by `RUN brew bundle --file=/tmp/Brewfile && rm -rf "$(brew --cache)"`. The cache removal is in the same `RUN` on purpose: the image sets `HOMEBREW_NO_INSTALL_CLEANUP=1`, so brew never purges `~/.cache/Homebrew`, and whatever bottle tarballs are on disk when the layer ends are committed permanently — with `ffmpeg`, `imagemagick`, `poppler`, `resvg`, and `node` in the set that is a large duplicate payload. Removing the cache manually does not reintroduce the race `HOMEBREW_NO_INSTALL_CLEANUP` guards, which is about post-install cleanup, not the download cache. Keep `/tmp/Brewfile` in the image — U2's verification and the Verification Contract both read it.
  2. Keep the existing individual `brew install chezmoi|bats-core|fzf|bun` layers above it — they change rarely and keep the fast toolchain cached even when the Brewfile layer rebuilds. **Any new `RUN brew install` line added above the bake forces a full 37-formula reinstall on the next build** (R2). The parallel-bats-suite plan's `RUN brew install parallel` is the live instance: place it *below* the bake, or drop it in favour of adding `parallel` to the Brewfile itself.
  3. Leave the apply path untouched: the run script's `brew bundle` still executes in-container and now verifies instead of installs (R3).
- **Patterns to follow:** existing `RUN brew install` layer style in the Dockerfile; `HOMEBREW_NO_AUTO_UPDATE`/`HOMEBREW_NO_INSTALL_CLEANUP` env already set above. `COPY --chown=testuser` is valid at this point — `testuser` is created earlier and `USER testuser` is already active — and `brew` is on `PATH` in `RUN` layers.
- **Test scenarios:** `Test expectation: none — image build; U3 owns behavioral proof.`
- **Verification:** `docker compose -f docker/docker-compose.yml run --rm ubuntu brew bundle check --file=/tmp/Brewfile` reports all dependencies satisfied. Record the resulting image size (`docker image ls`) alongside U3's timings.

### U3. Prove the speedup and non-regression

- **Goal:** measured before/after evidence, against a local baseline, that repeat runs got fast and nothing regressed.
- **Requirements:** R2, R3, R5, R6.
- **Dependencies:** U2 for the "after" half; the baseline step runs before U1.
- **Files:** none (measurement only).
- **Approach:**
  1. **Before U1 lands**, on current HEAD with a warm image: run `time make test-ubuntu` twice and record both the total wall time and the apply-phase time, splitting out the `brew bundle` portion from the Oh My Zsh / `mise` / fff-mcp portion (the apply runs with `--verbose`, so the phases are visible in the log). This is R6's baseline and the only trustworthy "before" number.
  2. After U2, repeat the same measurement from a warm image; confirm the apply log shows `brew bundle` completing in seconds with "Using <formula>" lines instead of "Installing".
  3. Run the cache probes below, then restore any scratch edits.
- **Test scenarios:**
  - Repeat `make test-ubuntu` with warm image: the `brew bundle` portion of the apply log completes in seconds, "Using" lines only. The whole package script stays slower — Oh My Zsh clones, `mise` node install, and fff-mcp remain per-run; record their measured cost for the follow-up named in Scope Boundaries.
  - **Over-broad-`COPY` probe:** change the *contents* of `home/private_dot_config/brewfiles/Brewfile.macos` — in-context under the KTD4 allowlist, never `COPY`'d — then `make build-docker` is fully cached. Change the contents, do not `touch`: Docker keys `COPY` layers on file content, not mtime, so a `touch` passes this probe vacuously whether or not the `COPY` is over-broad.
  - Brewfile content change: `make build-docker` rebuilds the bundle layer.
  - Brewfile content change followed immediately by `make test-templates`: record the wall time. This is R5's caller-visible regression — a target advertised as "fast, no apply" now pays a full image rebuild — and the number belongs in the PR description.
  - `make test-docker` completes green from the warm image.
  - `make shell-ubuntu` still opens a working shell.
- **Verification:** the six scenarios above pass; the before/after wall-time comparison from step 1 and step 2 is recorded in the eventual commit/PR description.

---

## Verification Contract

| Gate | Command | Proves |
|---|---|---|
| Baseline recorded | `time make test-ubuntu` ×2 on pre-change HEAD | R6 |
| Image builds, context minimal | `make build-docker` | U1, U2, R4 |
| Homebrew guards on all services | `docker compose -f docker/docker-compose.yml config` | Assumptions |
| All formulae present | `brew bundle check --file=/tmp/Brewfile` in container | R1 |
| Full suite green in container | `make test-ubuntu` and `make test-docker` | R3, R5 |
| Cache behavior | rebuilds per U3 scenarios | R2 |

## Definition of Done

- Repeat `make test-ubuntu` no longer installs Brewfile formulae during apply (`brew bundle` reports "Using" only); before/after repeat-run times recorded against the U3 step-1 baseline.
- Root `.dockerignore` exists with the KTD4 three-line allowlist; build context transfer is well under 1 MB.
- `test-quick` carries `HOMEBREW_NO_AUTO_UPDATE=1` and `HOMEBREW_NO_INSTALL_CLEANUP=1`.
- The baked layer removes the Homebrew download cache; resulting image size recorded.
- All four Make targets from R5 verified working, with the post-Brewfile-edit `make test-templates` cost measured and stated.
- No leftover scratch changes (the U3 Brewfile and Brewfile.macos probes) in the diff.

---

## Deferred / Open Questions

### From 2026-08-21 review

1. ~~**Landing order across the four same-date performance plans is undecided.**~~ **Settled 2026-08-21** — see Scope Boundaries and `docs/issues/2026-08-21-002-perf-plan-landing-order-undecided.md` (closed). The CI-minimal-brew-install plan lands first, so `Brewfile` is already `Brewfile.tmpl` when this plan starts and this plan owns the `chezmoi execute-template` render step plus the widened `.dockerignore` allowlist. One implementation detail the render step inherits and U2 must handle: `chezmoi execute-template` needs chezmoi data (`name`, `email`) available at image-build time.
2. **Should the container keep full-Brewfile fidelity (KTD5)?** If the CI-minimal plan's nightly full-Brewfile CI run is judged sufficient installability coverage, then setting `MMS_CI_MINIMAL=1` on the `test-quick` service is a strictly cheaper way to reach the same repeat-run speed — it drops U1, the `.dockerignore`, and the Dockerfile change entirely. KTD5 rejects it to preserve the one place the full Linux Brewfile is exercised end-to-end. Overturning KTD5 makes most of this plan unnecessary, so it is worth an explicit decision before implementation starts.
3. **Should `make clean` be changed to preserve BuildKit's build cache** once the bake exists, or is a full 37-formula reinstall an acceptable cost of `clean`?
4. **Baked formula freshness has no owner.** Versions refresh only when the Brewfile's content changes, not when upstream tap data does, and `HOMEBREW_NO_AUTO_UPDATE=1` freezes the image's formula index at first build. A months-later Brewfile edit resolves against that stale index and could fail on a withdrawn bottle. Neither this plan nor the CI-minimal plan states which path is the freshness backstop.
