---
title: python3 as a Declared Dependency, and git Out of the CI-Minimal Set - Plan
type: fix
date: 2026-08-21
status: open
topic: python3-declared-dependency
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
validate_commands:
  - timeout 300 bats tests/palette.bats
  - timeout 300 bats tests/templates.bats
  - make lint
---

# python3 as a Declared Dependency, and git Out of the CI-Minimal Set - Plan

## Goal Capsule

- **Objective:** Every environment this repository targets has `python3` for a reason the repository states, and a machine that lacks it says so loudly instead of quietly running fewer tests.
- **Means:** Install `python3` directly in the Docker test image, name it as a system requirement, replace the two skip guards with a named assertion, correct the comments that credit `grc` for supplying it, and drop `brew "git"` from the CI-minimal set now that the Docker test image ships a git new enough to read the deployed `.gitconfig`.
- **Product authority:** The test-suite policy for `python3`, where the dependency is declared, and the removal of `brew "git"` from the CI-minimal render. The removal of `brew "grc"` and the wider "package as carrier" pattern are not active scope.
- **Open blockers:** None. One sequencing constraint against the removal of `brew "grc"` is recorded under Dependencies / Assumptions.

---

## Product Contract

### Summary

Declare `python3` as a system requirement that this repository owns, on the same footing as `fzf`: it is the interpreter of the herdr command palette, not a convenience of the test suite. The Docker test image installs it directly, `README.md` names it, and the two bats guards that pretend it is optional become one assertion that names the interpreter when it is missing.

### Problem Frame

The bats suite carries two contradictory policies for `python3`. `tests/palette.bats:15` treats it as optional and skips. Nine call sites treat it as required and assert success: `tests/smoke.bats` at lines 190, 197, 200, 206, 276, 524, 798, 838, and `tests/scripts.bats:852`. `tests/scripts.bats:1789` skips again.

The disagreement is what makes a missing interpreter confusing. `python3` is required in practice, so the optional guard cannot save a run — it can only change what the failure looks like. That guard sits inside `setup()`, which bats runs before every test in the file, so one skip site silences all 56 tests in `tests/palette.bats`. A reader then sees a handful of red tests in `tests/smoke.bats` and a quietly shortened suite elsewhere, with nothing connecting the two.

Underneath the contradiction sits the reason it was never resolved: the repository has never said `python3` is a dependency. It is not in `home/private_dot_config/brewfiles/Brewfile.tmpl` or `home/private_dot_config/brewfiles/Brewfile.macos.tmpl`. It arrives in the Docker image only as a transitive dependency of `brew "grc"`, a package no code in the repository calls, and two comments record that accident as a reason: `home/private_dot_config/brewfiles/Brewfile.tmpl:31` and `tests/templates.bats:344`.

The cost is not confined to tests. The command palette is four Python files under `home/private_dot_config/herdr/plugins/command-palette/`, and its own manifest at `home/private_dot_config/herdr/plugins/command-palette/herdr-plugin.toml:12,18,24` declares three of them as `command = ["python3", ...]` entry points; `home/private_dot_config/herdr/command-palette/commands.toml:49` adds a fourth call site. `home/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl:28` pipes through `python3` during `chezmoi apply` itself; without an interpreter that call exits 127, the redirect swallows the message, and the script reports "failed to inspect obsolete plugin artisann.zed-herdr" — a diagnosis that names the wrong cause.

`fzf` is the contrast that shows the gap. It is the palette's scorer, and it is declared in `home/private_dot_config/brewfiles/Brewfile.tmpl:63` for real machines and installed again by each test harness that needs it. The palette's interpreter is declared nowhere.

### Key Decisions

- `python3` is a dependency this repository owns, not an optional tool. (session-settled: user-directed — chosen over adding guards to the nine bare call sites: no contributor without `python3` has ever worked here, and the interpreter runs a shipped feature rather than a test convenience.) Governs R1, R5.
- Declared as a system requirement, not as a Homebrew formula. Every target OS already ships `python3`; a formula would pin a version such as `python@3.14` and add install weight in every environment to supply something already present. Governs R2, R3.
- This plan owns the `docker/Dockerfile.ubuntu` edit rather than handing it to `docs/plans/2026-08-20-2217-perf-docker-baked-brewfile-plan.md`. (session-settled: user-directed — chosen over folding the edit into that plan: owning it keeps this work independently landable and unblocks the removal of `brew "grc"` on its own schedule, at the cost of touching the Dockerfile twice.) Governs R2.
- A missing interpreter is announced by a named assertion, not only by the mass of failures it causes. (session-settled: user-directed — chosen over relying on the roughly sixty-five identical `python3: command not found` failures: one named test states the cause where a log of identical messages leaves it to be inferred.) Governs R7.
- The two guards go now; a suite-wide strict switch does not. That switch would first need the same call for the roughly ninety-eight guards covering `jq`, `bun`, `sqlite3`, and `zsh`, none of which this work makes. Governs R5.
- `brew "git"` leaves the CI-minimal set in this plan rather than in a plan of its own. (session-settled: user-directed — chosen over filing it separately: `git` was folded into the minimal set solely because the Docker test image's apt git was too old to read the deployed `.gitconfig`, and this plan is the one that owns `docker/Dockerfile.ubuntu`, so the claim and the file that falsifies it stay together.) Governs R8, R9.

### Requirements

**Declaring the dependency**

- R1. `python3` is a stated system requirement of this repository, identified as the interpreter of the herdr command palette.
- R2. `docker/Dockerfile.ubuntu` installs `python3` itself, with a comment naming why, in the comment style of the `fzf` install already in that file. The mechanism is apt, not brew; only the comment convention is borrowed.
- R3. `README.md` carries a system-requirements statement that names `python3` and the minimum version the repository supports, 3.9. No such section exists today.
- R4. No comment in the repository claims that `grc` is the Docker image's only source of `python3`. Two carry that claim: `home/private_dot_config/brewfiles/Brewfile.tmpl:31` and `tests/templates.bats:344`.

**Test-suite policy**

- R5. No bats test skips because `python3` specifically is missing, excepting the interchangeable-JSON-parser fallback covered by R6. The guard at `tests/palette.bats:15` and the guard at `tests/scripts.bats:1789` are removed.
- R6. The `jq` / `python3` / `node` fallback at `tests/templates.bats:176` and `:266` is unchanged. That guard selects among interchangeable JSON parsers; it states no policy on whether `python3` is available.
- R7. Every test file that loses a guard or calls `python3` directly carries a named test asserting the interpreter is available and at least version 3.9, so a missing or too-old interpreter produces a failure that states the cause rather than only failures that exhibit it. The assertion body is shared, not copied.

**Removing the git carrier**

- R8. `brew "git"` renders in full mode only, so a push or pull-request CI run installs no git from Homebrew. Every environment that reads the deployed `.gitconfig` supplies a git of 2.35 or newer by other means.
- R9. No comment or test rationale still states that `git` must stay in the CI-minimal set because Ubuntu 22.04 ships git 2.34.1. Three carry that claim: `home/private_dot_config/brewfiles/Brewfile.tmpl:35`, `tests/templates.bats:343-351`, and `docker/Dockerfile.ubuntu:1-5`.

### Where python3 comes from

| Environment | Source today | Source after this work |
|---|---|---|
| macOS host | System `/usr/bin/python3`, undeclared | System `/usr/bin/python3`, declared in `README.md` |
| Linux host with Linuxbrew | Distribution package, undeclared | Distribution package, declared in `README.md` |
| Docker test image | Transitive dependency of `brew "grc"`, and only after `chezmoi apply` — the built image itself has none | `apt-get install -y python3` in the built image, with `grc` still shadowing it after the apply until that package is removed |
| GitHub `ubuntu-latest` job | Runner image | Runner image, unchanged |
| GitHub `macos-latest` job | Runner image | Runner image, unchanged |

The Docker row carries a nuance that matters for reading the result of this work. `docker/Dockerfile.ubuntu:37` puts the Linuxbrew prefix first on `PATH`, and `grc` pulls `python@3.14`, which links an unversioned `python3` into that prefix. So after the apply, brew's interpreter still wins over the apt one. The apt install changes nothing about which interpreter runs today; it guarantees one remains when `grc` leaves.

### Acceptance Examples

- AE1. Missing interpreter fails visibly and names itself
  - **Covers R5, R7.**
  - **Given:** a Linux environment with the repository applied and no `python3` on `PATH`.
  - **When:** the post-apply suite runs `bats tests/palette.bats`, `bats tests/scripts.bats`, and `bats tests/smoke.bats`.
  - **Then:** the file reports zero skips, and the named assertion fails with a message identifying `python3`. Expect 56 failures and one pass rather than 57 failures — `tests/palette.bats:196` is a bare `grep` over `commands.toml` and needs no interpreter.
- AE2. The image supplies its own interpreter
  - **Covers R2.**
  - **Given:** the image built from `docker/Dockerfile.ubuntu`, inspected before any `chezmoi apply` has run.
  - **When:** `python3 --version` runs in the image.
  - **Then:** it succeeds, where today it reports `command not found`.

- AE4. No comment credits the wrong package
  - **Covers R4.**
  - **Given:** the repository after this work.
  - **When:** the comments at `home/private_dot_config/brewfiles/Brewfile.tmpl:31` and `tests/templates.bats:344` are read.
  - **Then:** neither claims `grc` supplies `python3`, and the rendered Brewfile is byte-identical to the pre-change render in both the full and `MMS_CI_MINIMAL=1` modes.
- AE5. The CI-minimal render installs no git
  - **Covers R8.**
  - **Given:** a chezmoi config initialised with `MMS_CI_MINIMAL=1`.
  - **When:** `home/private_dot_config/brewfiles/Brewfile.tmpl` is rendered.
  - **Then:** the output carries no `brew "git"` line, and the full render still carries one.

No Key Flows section: this work changes a declaration and a guard policy, not a multi-step behavior. Requirements, Scope Boundaries, and the Acceptance Examples above cover the paths. No Actors section either, for the same reason — no multi-party behavior is involved.

### Scope Boundaries

- A suite-wide strict switch that turns every tool guard into a hard failure in CI and Docker. Same class of problem, roughly ninety-eight guard sites, separate work. The count breaks down as 81 `jq not available`, 7 `jq is required`, 7 `sqlite3 is required`, 2 `bun not available`, and 1 `zsh not installed`.
- The "package as carrier" pattern in general. `home/private_dot_config/brewfiles/Brewfile.tmpl:47` keeps `node` in the CI-minimal set solely as the Docker image's source of `sqlite3`, which seven tests guard on. Same accident as `grc` and `python3`; not fixed here.
- Removing `brew "grc"` itself, and the `assert_line --partial 'brew "grc"'` assertion at `tests/templates.bats:354` that pins it. Both belong to `docs/issues/2026-08-21-010-grc-is-vestigial-and-rgrc-was-never-moved-cross-platform.md`. `git` goes in U5 and `grc` does not, because different claims hold the two packages in: `git` is held by a statement about the Docker image's git version, which this plan's own Dockerfile history falsifies, while `grc` is held by a statement about `python3` that stays true until U1 lands and is then a separate call about a package this plan does not otherwise touch.
- Any `python3` entry in either Brewfile.
- `.github/workflows/test-dotfiles.yml`. Both runner images ship `python3`, and the ubuntu job never reaches the Linuxbrew prefix, so it already runs the system interpreter.
- The `jq` / `python3` / `node` fallback in `tests/templates.bats`, per R6.
- The swallowed error at `home/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl:28`. This work removes the trigger by declaring and installing the interpreter; the `2>/dev/null` redirect that turns any failure of that call into the wrong diagnosis is separate work.

#### Deferred to Follow-Up Work

- Coverage for the `tomllib` branch of `home/private_dot_config/herdr/plugins/command-palette/palette.py:156-171`. See Risks — the branch loses its Linux coverage when `grc` is removed, and no test asserts which parser ran.

### Dependencies / Assumptions

- **Sequencing against the `grc` removal.** R2 must land before `brew "grc"` leaves `home/private_dot_config/brewfiles/Brewfile.tmpl`, or the Docker image loses `python3` entirely. This plan carries no dependency in the other direction: it can land before `docs/plans/2026-08-20-2217-perf-docker-baked-brewfile-plan.md`, which reworks the same file later.
- **The palette tolerates an interpreter without `tomllib`.** `home/private_dot_config/herdr/plugins/command-palette/palette.py:156-171` imports `tomllib` only when available and falls back to its own parser otherwise. Verified: `tests/palette.bats` covers the fallback by monkeypatching `builtins.__import__` to raise `ModuleNotFoundError` for `tomllib`, which proves the fallback works under any interpreter.
- **Which interpreter version each environment actually runs is not verified.** Ubuntu 22.04's apt candidate is 3.10.6, measured with `docker run --rm ubuntu:22.04 apt-cache policy python3`. The other figures are unmeasured: the comment at `tests/palette.bats:433` asserts the Ubuntu CI job runs 3.10, but a comment is a claim rather than evidence, and `docs/plans/2026-08-20-2217-perf-parallel-bats-suite-plan.md` treats `ubuntu-latest` as ubuntu-24.04, which ships a newer Python. Resolve this by printing `python3 -V` in a CI step before relying on any per-environment version.
- **The supported floor is Python 3.9, measured not assumed.** macOS ships `/usr/bin/python3` at 3.9.6, the oldest interpreter any target provides. All four palette sources compile under it and `palette.py --validate` exits 0 against the real `commands.toml`, verified on this checkout. The floor is therefore a commitment the palette must keep, not a limit it currently strains against: a future 3.11+ feature in those sources breaks macOS hosts, and the R7 assertion is what reports it.
- **Every target OS ships `python3`.** macOS provides `/usr/bin/python3` behind Xcode Command Line Tools, which Homebrew already requires; Ubuntu and Debian ship it in the base install; both GitHub runner images provide it. The runner evidence is the complete ubuntu skip list quoted in `docs/issues/2026-08-21-007-linuxbrew-prefix-unreachable-in-ubuntu-ci-job.md`, which contains no `python3` skip.

### Outstanding Questions

None. Every question document review raised was resolved into the plan.

### Sources / Research

- `docs/issues/2026-08-21-009-python3-is-both-required-and-optional-in-the-test-suite.md` — the originating issue, with the site-by-site policy table. Note it cites the palette guard at line 14 and counts seven required call sites; the guard is at line 15 and there are nine.
- `docs/issues/2026-08-21-010-grc-is-vestigial-and-rgrc-was-never-moved-cross-platform.md` — establishes that `grc` is called by nothing, costs 21 s of the Ubuntu install, and survives only as the `python3` carrier.
- `docs/issues/2026-08-20-013-se-blocks-test-hard-fails-without-deps.md` — the closed issue that established the suite's skip convention and named `python3` as one of the tools it covers. This plan's R5 is an explicit exception to it; KTD4 records why.
- `docs/issues/2026-08-21-007-linuxbrew-prefix-unreachable-in-ubuntu-ci-job.md` — the ubuntu job's skip list, which is the evidence that the runner image supplies `python3`, `jq`, `git`, `sqlite3`, and `perl`.
- `docker/Dockerfile.ubuntu:53-55` — the `fzf` install and its comment, the precedent this work follows for a palette runtime dependency in the test image.
- `home/private_dot_config/brewfiles/Brewfile.tmpl:16-18, 31-32, 47, 63` — the byte-identity claim about template comments, the `grc` comment naming the accident, the parallel `node`-as-`sqlite3`-carrier comment, and the `fzf` entry inside the `$full` guard.
- `home/private_dot_config/herdr/plugins/command-palette/herdr-plugin.toml:12,18,24` — three `command = ["python3", ...]` entry points for `open.py`, `smart_close.py`, and `palette.py`. This is the primary evidence that `python3` runs a shipped feature.
- `home/private_dot_config/herdr/command-palette/commands.toml:49` — one further literal `python3` command string, for `open_in_zed.py`.
- `CONCEPTS.md` — "Dead leg" states the repo's own never-fail-open principle: absence of signal must not read as a pass. A `skip` in `setup()` that silences 56 tests is that failure mode in the test suite.

---

## Planning Contract

### Product Contract preservation

Changed: R4 widened from one stale comment to both (`tests/templates.bats:344` carries the same claim and was missed at brainstorm time). R6 narrowed from "`tests/templates.bats` unchanged" to the JSON-parser fallback specifically, because R4 now edits a comment elsewhere in that file. R7 added — a named assertion for the missing interpreter. The Problem Frame's call-site count corrected from seven to nine. All three changes were confirmed with the user during planning; no scope was removed.

Document review then corrected four factual errors in the planning layer without changing product scope: AE1's failure count (56 and one pass, not 57), the `tomllib` assumption's unearned "Verified" label, the deferred guard count (ninety-eight, not forty-five), and KTD1's claim that CI pays the image-rebuild cost. Three review contexts across two model families independently found that `tests/scripts.bats` was missing from the runnable gate; measuring it at 5 min 11 s resolved that as a stated exclusion rather than an addition.

Two review findings then changed product scope with the user's agreement. R7 widened from one named test in one file to a shared assertion body in `tests/helpers/common.bash` called from three files — the two that lose guards and `tests/smoke.bats`, which holds eight of the nine bare call sites. The acceptance example for a fresh macOS machine was deleted rather than rewritten: it passed identically before and after the work, so it verified nothing, and R1 and R3 are documentation whose correctness is reviewed rather than executed. The numbering keeps its gap — AE1, AE2, AE4 — because stable IDs are never reused. R3 gained a minimum supported version, 3.9, measured as the interpreter macOS ships at `/usr/bin/python3` — the oldest any target provides, and the one all four palette sources were confirmed to compile and validate under.

A later user-directed addition widened product scope once more: R8 and R9 remove `brew "git"` from the CI-minimal render, with AE5, KTD5 and U5 supporting them. This is a second package leaving the minimal set, so it does touch the "package as carrier" pattern the Goal Capsule excludes — the distinction the Scope Boundaries now state is that `git`'s justifying claim is about the Docker image's git version and is already falsified by `docker/Dockerfile.ubuntu` moving to `ubuntu:24.04`, whereas `grc`'s claim is about `python3` and stays live until U1 lands. Nothing was removed from the existing scope.

### Key Technical Decisions

- KTD1. `python3` joins the existing apt layer at `docker/Dockerfile.ubuntu:8-18` rather than getting its own `RUN`. It is a system package and that layer is where system packages live. The cost is a full image rebuild — that layer is the first `RUN`, so every layer below it, including the Linuxbrew bootstrap and four `brew install` layers, invalidates once. That cost falls on local Docker users only: no CI job builds this image. A separate later layer would preserve the cache but would need its own `apt-get update` and would put a system package below the Homebrew bootstrap that has no reason to depend on it. Governs R2.
- KTD2. The `Brewfile.tmpl` comment stays a Go template comment in the `{{/* … */ -}}` form, never a plain `#` comment. Every comment the CI-minimal guard added is a template comment by design (`home/private_dot_config/brewfiles/Brewfile.tmpl:16-18`), which is what keeps the guarded render byte-identical to the pre-guard file. The file's section headings (`# Taps`, `# Git tools`, and the rest) are deliberately plain `#` comments that do render, so "every comment in the file is a template comment" is not true and must not be used as the reason. Converting line 31 to `#` would add a line to the rendered Brewfile. Dropping the `-}}` trim marker inserts a blank line before `brew "grc"`, and no test catches that. Governs R4.
- KTD3. The R7 assertion body lives in `tests/helpers/common.bash`, beside `command_exists()`, and three files call it from their own named test placed first: `tests/palette.bats` and `tests/scripts.bats`, which lose guards, and `tests/smoke.bats`, which loses none but holds eight of the nine bare call sites. Putting the only assertion in `tests/palette.bats` would leave the other two with the unnamed failures R7 exists to prevent. A contributor running one file alone is the case that matters, because the repository documents that as the way to run a single file. Governs R7.
- KTD4. Removing the two guards is a named exception to the skip convention, not a reversal of it. `docs/issues/2026-08-20-013-se-blocks-test-hard-fails-without-deps.md` established that convention and listed `python3` among the tools it covers. The discriminator is not "declared" on its own — `jq`, `git`, `node`, `bun`, and `fzf` are all declared in `home/private_dot_config/brewfiles/Brewfile.tmpl` and keep their guards, 88 of them for `jq` alone. It is that the repository does **not** install `python3` and a shipped feature invokes it during `chezmoi apply` itself, so its absence is a broken machine rather than a missing convenience. A Brewfile entry is a promise the repository installs the tool; a README system requirement is a precondition the repository only checks. The comment left at each removal site states this, or the next contributor restores the guard citing 013 — or cites this decision to delete the `jq` guards. Governs R5.
- KTD5. `brew "git"` joins the `{{ if $full -}}` block that already exists two lines below it, rather than getting a guard of its own. The whole edit is: delete the rationale comment at `home/private_dot_config/brewfiles/Brewfile.tmpl:35`, then move the `{{ if $full -}}` opener from `:37` up to sit directly under the `# Git tools` heading, so `brew "git"` falls inside it alongside `gh`, `delta`, and `lazygit`. Leave the closing `{{ end }}` at `:45` exactly as it is — it deliberately carries no trim marker, so the blank line before `# JavaScript runtimes` is emitted in both render modes, and adding a marker silently changes the full render. Governs R8.

### Assumptions

- The host running `bats tests/palette.bats` has `python3`. Every environment this repository targets does, per the Dependencies section; the R7 assertion is what reports the exception rather than leaving it to be inferred.
- `docs/plans/2026-08-20-2217-perf-docker-baked-brewfile-plan.md` will rework `docker/Dockerfile.ubuntu` later and will carry the apt line forward. This plan does not coordinate with it beyond landing first.

### Risks

- **The Docker image's interpreter changes version when `grc` is removed, and no test reports which parser the palette used.** Today the image runs the palette on Homebrew's Python 3.14, where `tomllib` exists. Once `grc` leaves, it drops to apt's 3.10.6 and takes the fallback parser at `home/private_dot_config/herdr/plugins/command-palette/palette.py:156-171`. Whether that loses the branch's only real-interpreter coverage depends on which Python the GitHub jobs run, which is unverified — see Dependencies / Assumptions. The switch is silent either way, because the only `tomllib` test forces the fallback by monkeypatching the import rather than observing the interpreter. This plan does not cause the change — `grc`'s removal does — but this plan is where it becomes foreseeable. Mitigation: the Definition of Done requires writing it into `docs/issues/2026-08-21-010`.
- **Editing the `Brewfile.tmpl` comment re-arms the package-install script.** `home/.chezmoiscripts/run_onchange_after_1-install-packages.sh.tmpl:12` embeds `sha256sum` of the template's raw source, and `include` reads source rather than render. So a render-neutral comment edit still changes the hash, and `make test-local` on the host will show the install script as pending until the next apply. Self-clearing and harmless in Docker and CI, which start from fresh state. Accept it; do not work around it by leaving a false comment in place.
- **No automated gate protects the apt install.** No job in `.github/workflows/test-dotfiles.yml` builds `docker/Dockerfile.ubuntu` — the three jobs are `test-ubuntu` (which runs natively on the runner), `test-macos`, and `lint`. Both commands that prove R2 need Docker and run locally. If the sibling rework of that file drops the apt line, nothing catches it until someone runs the Docker suite by hand.
- **Removing `git` alone does not reach the CI-minimal work's wall-clock target.** The first measured minimal install on Ubuntu was 53.5 s against a target of 35.6 s or less, and `git` accounts for 15.1 s of that. Dropping it lands around 38.4 s — a real improvement, still roughly 3 s short. The rest of the overrun sits in `grc`, which this plan does not remove. Do not report the target as met on the strength of U5; report the measured number.
- **The `.gitconfig` claim is only as good as the oldest environment that reads it.** `home/dot_gitconfig.tmpl:27` sets `merge.conflictStyle = zdiff3`, which needs git 2.35 or newer, and U5 rests on every environment supplying that itself: `ubuntu:24.04` ships 2.43.0, and both GitHub runner images ship a current git — the ubuntu skip list in `docs/issues/2026-08-21-007-linuxbrew-prefix-unreachable-in-ubuntu-ci-job.md` names `git` among the tools the runner already provides. A later base-image downgrade re-breaks the apply's Oh My Zsh clone before any test runs, and the failure names `zdiff3` rather than `git`. The comment U5 leaves in `docker/Dockerfile.ubuntu` is what keeps that connection findable.
- **The skip-count parity baseline resets.** The CI-minimal work proves its render pair by comparing skip counts by hand (`docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md`, KTD6); there is no automated gate. Removing up to 56 potential skips means any future comparison must be taken against a post-change baseline, not a recorded pre-change number.

### Sequencing

U1 first, so the image supplies its own interpreter before anything depends on that being true, and so the plan's ordering constraint against the `grc` removal holds at every intermediate commit.

The rest fall out of two real dependencies, and the units' own Dependencies fields are authoritative. U3 needs U1, because the comments it rewrites only become false once the image installs its own interpreter. U2 needs U4, because the assertion U2 adds points a reader at a README section U4 creates. U4 itself depends on nothing. So the order is U1, then U4, then U2 and U3 in either order. If a unit's Dependencies field and this paragraph ever disagree, the field wins.

U5 depends on none of them. The change that enables it — `docker/Dockerfile.ubuntu` moving to `ubuntu:24.04`, whose apt git is 2.43.0 — is already on `main` in commit `f83e95d`. Land U5 last regardless, so that if the Docker suite reddens, the missing `git` is the only variable in that commit.

---

## Implementation Units

### U1. Install python3 in the Docker test image

- **Goal:** The image built from `docker/Dockerfile.ubuntu` has `python3` without depending on any Homebrew formula.
- **Requirements:** R2. Covers AE2.
- **Dependencies:** none.
- **Files:** `docker/Dockerfile.ubuntu`
- **Approach:**
  1. Add `python3` to the package list of the existing apt layer (`docker/Dockerfile.ubuntu:8-18`), one package per continuation line, matching the surrounding style.
  2. Extend the comment above that `RUN` to state why `python3` is there: it is the interpreter of the herdr command palette, and the image must not rely on `brew "grc"` to supply it. Follow the file's convention — comment above the `RUN`, never inline, stating why the package cannot come from elsewhere, as at `docker/Dockerfile.ubuntu:53-55`.
- **Execution note:** This is packaging, so the proof is a runtime check in the built image rather than unit coverage.
- **Patterns to follow:** the `fzf` install and its rationale comment at `docker/Dockerfile.ubuntu:53-55`; the longer `bun` rationale at `:57-62`.
- **Test scenarios:**
  - Covers AE2. `python3 --version` inside the freshly built image, before any `chezmoi apply`, exits 0 and prints a 3.10 version. Today the same command reports `command not found`.
  - The image builds to completion from a clean cache, with no apt resolution error on the new package.
  - In the Docker pre-apply `bats tests/templates.bats` gate, the two JSON-shape tests change from skip to pass. The image installs no `jq` and no `node`, so the three-way parser fallback at `tests/templates.bats:176` and `:266` currently reports `no JSON parser available (jq/python3/node)`; with `python3` present it takes the `python3 -m json.tool` branch. Two assertions that have never run in that environment start running, and the Docker `templates.bats` skip count drops by two.
- **Verification:** `make build-docker` succeeds, and `docker compose -f docker/docker-compose.yml run --rm ubuntu python3 --version` prints a version.

### U2. Make the bats suite treat python3 as required

- **Goal:** No test skips on a missing `python3`, and every file that depends on the interpreter reports the cause by name when it is missing or older than 3.9.
- **Requirements:** R5, R7. Covers AE1.
- **Dependencies:** U1, U4. U4 must land first: the assertion this unit adds points a reader at the README section U4 writes, and a pointer to a section that does not exist is worse than the unnamed failure it replaces.
- **Files:** `tests/helpers/common.bash`, `tests/palette.bats`, `tests/scripts.bats`, `tests/smoke.bats`
- **Approach:**
  1. Delete the guard line `command_exists python3 || skip "python3 not installed"` from `setup()` in `tests/palette.bats:15`. Nothing below it in `setup()` depends on it, and `teardown()` reads only `PALETTE_WORK`.
  2. Add a helper to `tests/helpers/common.bash`, beside `command_exists()`, that asserts `python3` is on `PATH` and reports at least version 3.9. Its failure message names the interpreter, names the version it found, and points at the `README.md` requirements section as the place the requirement is stated.
  3. Call that helper from a named `@test` placed first in `tests/palette.bats`, `tests/scripts.bats`, and `tests/smoke.bats`. The first two lose a guard; the third loses none but holds eight of the nine bare `run python3` call sites, so a contributor running it alone still needs the cause named.
  4. Delete the guard line `command -v python3 >/dev/null || skip "python3 not available"` from `tests/scripts.bats:1789`. The guard is the first line of the test body; the rest of the body stands on its own.
  5. At each removal site, leave a short comment recording that `python3` is a declared requirement and that this is a deliberate exception to the skip convention in `docs/issues/2026-08-20-013-se-blocks-test-hard-fails-without-deps.md`.
- **Execution note:** Do not touch `tests/scripts.bats:1767` — `[ -n "${HTS_DESCRIPTOR_PID_FILE:-}" ] || skip "internal descriptor probe"` is a deliberate always-skip probe, not a tool guard.
- **Patterns to follow:** `command_exists()` at `tests/helpers/common.bash:70-72`; the assertion style of the existing `R9: a missing fzf fails loudly, naming fzf, the Brewfile and PATH` test in `tests/palette.bats`, which is the closest precedent for a test that reports a missing tool by name.
- **Test scenarios:**
  - Covers AE1. With `python3` present, each of the three files reports one more passing test than before and zero `python3` skips: `tests/palette.bats` 57 (up from 56), `tests/scripts.bats` 195 (up from 194), `tests/smoke.bats` 71 (up from 70).
  - Covers AE1. With `python3` absent from `PATH`, the named test in each of the three files fails with a message identifying `python3`, and no test in any of them reports `skip`.
  - With a `python3` older than 3.9 first on `PATH`, the named test fails and its message states the version it found. Stub this the way `tests/palette.bats:924-941` stubs a missing `fzf`, rather than installing an old interpreter.
  - `bats tests/scripts.bats` reports no `python3 not available` skip, and the test formerly at `:1789` executes its body.
  - The deliberate probe skip `internal descriptor probe` still appears in the `tests/scripts.bats` output.
- **Verification:** `bats tests/palette.bats`, `bats tests/scripts.bats`, and `bats tests/smoke.bats` pass on the host; the palette file rises from 56 tests to 57, the scripts file from 194 to 195, and the smoke file from 70 to 71, with no `python3` skip in any of them.

### U3. Correct the stale python3-carrier comments

- **Goal:** No comment credits `grc` with being the image's only source of `python3`.
- **Requirements:** R4.
- **Dependencies:** U1 — the claim only becomes false once the image installs `python3` itself.
- **Files:** `home/private_dot_config/brewfiles/Brewfile.tmpl`, `tests/templates.bats`
- **Approach:**
  1. Rewrite the template comment at `home/private_dot_config/brewfiles/Brewfile.tmpl:31` so it no longer says `grc` is the only source of `python3`, and no longer cites `tests/palette.bats` as guarding on it. Keep it in the `{{/* … */ -}}` form with the trim marker intact, per KTD2. What keeps `grc` in the file now is `docs/issues/2026-08-21-010`, not this claim; point there.
  2. Rewrite the corresponding sentence in the prose comment at `tests/templates.bats:343-351`, which currently reads "grc for the python3 that gates all of palette.bats". State the same replacement claim step 1 uses: after U1 and U2, `grc` has no remaining consumer in the suite and is pinned only until `docs/issues/2026-08-21-010` removes it. Do not invent a new justification — the surrounding block declares that every entry is there because removing it broke something observable, and that is no longer true of this one. Leave the `assert_line --partial 'brew "grc"'` assertion at `:354` in place; removing the entry belongs to that issue.
- **Execution note:** The render must stay byte-identical, and `bats tests/templates.bats` does not prove that on its own — it asserts which lines are present, not that no line was added. Capture the rendered Brewfile before and after the edit in both modes and diff the two pairs, using `write_test_config` from `tests/helpers/common.bash` (once with `MMS_CI_MINIMAL=1`, once unset) with the config-scoped render helper; a plain `chezmoi execute-template` cannot reproduce the minimal render, because the `ci_minimal` data key binds at `chezmoi init`. Confirm by eye that the `-}}` trim marker survived: dropping it inserts a blank line before `brew "grc"` that no test catches.
- **Patterns to follow:** the template-comment style already used throughout `home/private_dot_config/brewfiles/Brewfile.tmpl`; the byte-identity rationale stated at `:16-18`.
- **Test scenarios:**
  - `bats tests/templates.bats` passes, including the full and `MMS_CI_MINIMAL=1` render assertions.
  - The rendered Brewfile is unchanged in both modes — no added or removed line, no blank line introduced before `brew "grc"`.
  - No comment in the repository still asserts that `grc` is the only source of `python3`.
- **Verification:** `bats tests/templates.bats` passes and a render diff against the pre-change output is empty in both modes.

### U4. State the system requirements in README.md

- **Goal:** A reader setting up a new machine learns that `python3` must already be present, and why.
- **Requirements:** R1, R3. No acceptance example: the deliverable is prose, and its correctness is reviewed rather than executed.
- **Dependencies:** none.
- **Files:** `README.md`
- **Approach:**
  1. Add a short `## Requirements` section between the one-line intro and `## Quick Start (new machine)`. That placement avoids renumbering the existing steps 1 through 5 inside Quick Start.
  2. Name `python3`, state the minimum supported version as 3.9, and say what needs it — the herdr command palette. Say that every supported OS ships a new enough interpreter, so this is a check rather than an install step. The floor is 3.9 because that is what macOS ships at `/usr/bin/python3`; it is the version the palette sources must keep working on. Match the existing per-step style: imperative, with one sentence of rationale, as at `README.md:20`.
  3. Match the macOS and Linux split that `## Platforms` already uses, since the three environments obtain `python3` by different routes.
- **Test scenarios:** none — no test asserts `README.md` content, and nothing in the repository lints or renders it. The requirement is documentation, and its correctness is reviewed rather than executed.
- **Verification:** the section names `python3` and the 3.9 floor, states what needs it, and does not claim the repository installs it.

### U5. Drop git from the CI-minimal Brewfile set

- **Goal:** A push or pull-request CI run installs no git from Homebrew, and nothing in the repository still claims it has to.
- **Requirements:** R8, R9. Covers AE5.
- **Dependencies:** none inside this plan. The enabling change is already on `main`: `docker/Dockerfile.ubuntu` moved to `ubuntu:24.04`, whose apt git is 2.43.0, in commit `f83e95d`.
- **Files:** `home/private_dot_config/brewfiles/Brewfile.tmpl`, `tests/templates.bats`, `docker/Dockerfile.ubuntu`
- **Approach:**
  1. In `home/private_dot_config/brewfiles/Brewfile.tmpl`, delete the `{{/* git is kept … */ -}}` comment at `:35` and move the `{{ if $full -}}` opener at `:37` up under the `# Git tools` heading, per KTD5. `brew "git"` then renders in full mode only.
  2. In `tests/templates.bats`, delete `assert_line 'brew "git"'` from `assert_minimal_brewfile()` at `:355`, and add `refute_line 'brew "git"'` to the refute block below it. The removal must be pinned by an assertion rather than merely left unasserted, or a later fold-back passes silently.
  3. Rewrite the `git` sentence in that helper's rationale comment at `tests/templates.bats:343-351`. The comment's own rule is that every entry is present because removing it broke something observable; `git` no longer qualifies, so it leaves the list rather than being given a softer reason.
  4. Rewrite the header comment at `docker/Dockerfile.ubuntu:1-5`. It currently justifies the 24.04 choice by `git` having to stay in the CI-minimal set, which stops being true here. Keep the `zdiff3` requirement — that is why the base image must not go back to 22.04 — and drop the CI-minimal clause.
- **Execution note:** This is a removal, so the proof is that the existing suite still passes with the package gone, not that a new test passes. Run the full-render Docker suite as well as the minimal one; the full render must be untouched.
- **Patterns to follow:** the `{{ if $full -}}` … `{{ end -}}` blocks already in `home/private_dot_config/brewfiles/Brewfile.tmpl` at `:27-30` and `:53-57`; the evidence rule stated in the `assert_minimal_brewfile()` comment.
- **Test scenarios:**
  - Covers AE5. `MMS_CI_MINIMAL=1` renders a Brewfile with no `brew "git"` line, and the full render still has one.
  - The full render is byte-identical to the pre-change full render — no line moved, no blank line gained or lost around `# Git tools`.
  - The minimal-render Docker suite completes the apply, including the Oh My Zsh clone that git 2.34.1 used to abort, and its skip set matches the full-render run's on the same image. A new skip naming `git` is the signal to fold the package back, not to accept a new baseline.
- **Verification:** `bats tests/templates.bats` passes; a full-render diff against the pre-change output is empty; `MMS_CI_MINIMAL=1 docker compose -f docker/docker-compose.yml run --rm test-full` reaches the end of the apply with a skip set matching the full run's. Note that `make test-ubuntu` cannot serve as this gate — it runs the `test-quick` service, which sets no `MMS_CI_MINIMAL` and therefore installs the full Brewfile.

---

## Verification Contract

| Command | What it proves | Covers | Applicability |
|---|---|---|---|
| `timeout 300 bats tests/palette.bats` | 57 tests, zero skips; the new assertion is present and passes | U2 | Host and CI. Verified green at 56 tests before the change |
| `timeout 300 bats tests/templates.bats` | The guard's line selection still holds in both modes after the comment edit | U3 | Host and CI. Verified green at 38 tests before the change. Byte-identity is the manual diff in U3's execution note, not this command |
| `make lint` | shellcheck still passes | none (regression guard) | Host and CI. Unaffected by this diff — Dockerfiles, `.bats` and `.py` files are outside its globs |
| `make build-docker` | The new apt layer resolves and the image builds | U1 | Requires Docker. Expect a full rebuild — the apt layer is the first `RUN` |
| `docker compose -f docker/docker-compose.yml run --rm ubuntu python3 --version` | The image has `python3` before any apply | U1 (AE2) | Requires Docker. Manual check. This is the only command that observes the apt interpreter |
| `docker compose -f docker/docker-compose.yml run --rm ubuntu env PATH=/usr/bin:/bin python3 "$HOME/dotfiles/private_dot_config/herdr/plugins/command-palette/palette.py" --validate "$HOME/dotfiles/private_dot_config/herdr/command-palette/commands.toml"` | The palette actually runs on the apt interpreter, not just that the binary exists | U1 (AE2) | Requires Docker. Manual check. Proves the interpreter R2 guarantees can run the shipped feature before `grc` leaves |
| `make test-ubuntu` | The whole change set applies end to end | U1, U2, U3 | Requires Docker. Does **not** exercise the apt interpreter: the `test-quick` service sets no `MMS_CI_MINIMAL`, so the apply installs the full Brewfile including `grc`, and the Linuxbrew prefix at `docker/Dockerfile.ubuntu:37` shadows `/usr/bin/python3` for every post-apply test |
| `timeout 600 bats tests/scripts.bats` | The removed guard's test runs, and the deliberate probe skip remains | U2 | Host and CI. Measured at 5 min 11 s for 194 tests, which is why it is not in `validate_commands` |
| `timeout 300 bats tests/templates.bats` | The minimal render carries no `brew "git"`; the full render still does | U5 | Host and CI. Same command as the U3 row, different assertions |
| `MMS_CI_MINIMAL=1 docker compose -f docker/docker-compose.yml run --rm test-full` | The apply completes without Homebrew's git, and the minimal skip set still matches the full run's | U5 | Requires Docker. The only gate that exercises the removal. `make test-ubuntu` cannot substitute — it runs `test-quick`, which sets no `MMS_CI_MINIMAL` |

The three commands in the `validate_commands` frontmatter list are the machine-runnable subset: they need no Docker, terminate on their own, and leave the worktree clean. All three were run on this checkout before the plan was written and exited 0.

`timeout 600 bats tests/scripts.bats` meets those three criteria and is still excluded, on runtime alone: measured at 5 min 11 s against roughly 30 s for the other three combined, it would dominate a gate an executor reruns on every iteration. U2 edits that file, so run it once before the unit is called done — the Definition of Done requires it — rather than on every loop.

---

## Definition of Done

- `docker/Dockerfile.ubuntu` installs `python3` in its apt layer with a comment naming why, and `python3 --version` succeeds in the built image before any apply.
- `tests/helpers/common.bash` carries a shared assertion that `python3` is present and at least 3.9, whose failure message names the interpreter, the version found, and the `README.md` requirements section.
- `tests/palette.bats` has no `setup()` skip on `python3`, reports 57 tests and zero skips, and its first test calls that assertion.
- `tests/scripts.bats:1789`'s guard is gone, its first test calls the same assertion, it reports 195 tests, and the deliberate probe skip at `:1767` remains.
- `tests/smoke.bats` carries the same assertion as its first test, covering the eight bare `run python3` call sites it holds.
- Each guard removal site carries a comment recording the exception to the skip convention in `docs/issues/2026-08-20-013-se-blocks-test-hard-fails-without-deps.md`.
- No comment in the repository claims `grc` is the only source of `python3`, and the Brewfile render is byte-identical in both modes.
- `README.md` has a requirements section naming `python3`, the 3.9 floor, and what needs them.
- `docs/issues/2026-08-21-010-grc-is-vestigial-and-rgrc-was-never-moved-cross-platform.md` records two things this plan established: that `docker/Dockerfile.ubuntu` now installs `python3` itself and R2 must already be landed before `brew "grc"` is removed, and that removing `grc` drops the image from Homebrew's 3.14 to apt's 3.10.6, changing which TOML parser the palette uses with no test observing it. The person who removes `grc` works from that issue, not from this plan.
- `timeout 300 bats tests/palette.bats`, `timeout 300 bats tests/templates.bats`, and `make lint` all exit 0.
- `timeout 600 bats tests/scripts.bats` exits 0, run once at the end rather than on every iteration.
- `brew "git"` renders in full mode only, `tests/templates.bats` refutes it in the minimal render, and no comment in the repository still says `git` must stay in the CI-minimal set because of Ubuntu 22.04's git 2.34.1.
- `MMS_CI_MINIMAL=1 docker compose -f docker/docker-compose.yml run --rm test-full` completes the apply and reports a skip set matching the full-render run's.
- `make test-ubuntu` passes.
