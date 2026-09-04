---
title: Skip-set parity, not a green suite, proves a reduced dependency set
date: 2026-08-21
category: design-patterns
module: ci
problem_type: design_pattern
component: testing_framework
severity: high
resolution_type: workflow_improvement
related_components:
  - tooling
applies_when:
  - "Reducing an installed dependency set (CI minimal install, slimmer Docker image, pruned Brewfile) and needing proof the tests still exercise the same ground"
  - "The test suite guards tests with `command -v X || skip`, so a missing tool skips silently instead of failing"
  - "Declaring a suite green under a reduced configuration from exit codes or pass counts alone"
  - "A static audit classifies a dependency as environment-provided because a binary of it exists on PATH"
  - "Choosing the pass condition for an A/B verification run of two environment configurations"
symptoms:
  - "The suite exits 0 under the minimal install while dozens of tests silently stopped running behind `command -v` skip guards"
  - "Skip counts match between two runs, but a count-only comparison would still pass if one skip were swapped for a different one"
  - "The audit called `git` environment-provided, but the deployed gitconfig sets `merge.conflictStyle = zdiff3`, which apt's git 2.34 rejects — the apply aborted before any test ran"
tags:
  - skip-parity
  - test-skip-guards
  - ci
  - bashunit
  - brewfile
  - minimal-install
  - empirical-verification
  - dependency-audit
---

# Skip-set parity, not a green suite, proves a reduced dependency set

## Context

The CI-minimal brew install work (plan `docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md`, status done; landed via PR #26 `1e4ea73` and PR #27 `f83e95d`, both reachable from `main`) cut the packages installed on push/PR CI runs from 37 formulae to a handful. Reducing an installed package set under a test suite raises one question: how do you *prove* the reduced set is sufficient?

The trap is that this suite — like most — treats a missing tool as a **skip, not a failure**. The idiom is `command -v <tool> || skip "..."`, and the runner exits 0 on a skipped test. (The suite ran on bats when this was written and has since migrated to bashunit, whose DSL keeps the same `skip` semantics and the same exit-0 behaviour — 149 skip sites across `tests/bashunit/*_test.sh` today.) The plan's key decision KTD6 (`docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md:84`) counted 127 skip sites in the then-current `tests/*.bats`, 88 gated on `jq` alone. So "the suite passed on the minimal render" cannot distinguish a correct minimal set from one that silently stopped exercising dozens of tests.

Two coupled findings came out of the work:

1. **Skip parity, not suite green, is the proof obligation.** The verification ran the full Docker suite twice — once with `MMS_CI_MINIMAL=1`, once unset — and required the skip *sets* to be identical, not just the exit code.
2. **A tool existing is not the same as the deployed config accepting it.** The static dependency audit classified `git` as environment-provided because a git binary existed everywhere. It missed that the deployed config demands a *newer* git than apt ships — and only the empirical run caught it.

## Guidance

### The parity mechanism

- Run the complete suite under the **full** environment and under the **reduced** environment.
- Extract every skipped test **with its skip reason**, and diff the two sets. Equal counts are necessary; identical sets are the real gate — a swap of one skip for another must still fail the comparison (`docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md:190`).
- The pass condition is stated in the plan's U2 verification: "**Equal skip counts is the pass condition; a passing run is not**" (`:182`), with requirement R7 (`:57`): "An undersized minimal set must fail the suite, not silently reduce what it covers."
- Recorded outcome (U2 "Verification outcome (2026-08-21)", `:183-192`): both renders produced **367 ok / 1 not ok / 15 skipped**, skip sets identical line for line; the single failure was the same pre-existing harness gap in both renders (already filed as `2026-08-19-001`), so it did not mask anything.
- Any package whose absence changes the skip set **folds back** into the minimal set — that is the stop condition, not a judgment call (`:31`, `:182`).
- **Count skipped tests, never skip sites** (session history): a guard inside `setup()` runs before every test in the file — a `command_exists python3 || skip` guard in the palette suite's `setup()` silenced every test in that file from one site. A site count understates the coverage at risk by an order of magnitude; the discovery is filed as `2026-08-21-009`, which credits the parity gate — not ordinary CI — with surfacing it.

### The config-compatibility trap (the git fold-back)

The first parity attempt fired the stop condition before a single test ran (`docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md:154`):

- The deployed `home/dot_gitconfig.tmpl:27` sets `conflictStyle = zdiff3` (under `[merge]`), which requires git >= 2.35.
- ubuntu:22.04's apt git is **2.34.1**; it rejects the option with `fatal: unknown style 'zdiff3' given for 'merge.conflictstyle'`, and `chezmoi apply` died in ~57 seconds on `Error: git clone of oh-my-zsh repo failed` — the Oh My Zsh clone reads the deployed gitconfig.
- The audit had been *right that a git binary existed*, and wrong that it sufficed: Linuxbrew's newer git had been silently satisfying the config all along. `git` went back into the minimal set (`home/private_dot_config/brewfiles/Brewfile.tmpl:35-36` carries the rationale comment).
- Later, PR #27 (`f83e95d`) moved `docker/Dockerfile.ubuntu` to `FROM ubuntu:24.04` (`docker/Dockerfile.ubuntu:9`), whose git 2.43.0 accepts zdiff3 — the header comment at `docker/Dockerfile.ubuntu:1-5` documents exactly this chain.

The durable lesson: **a static audit of "which binaries exist" cannot see version- and config-compatibility constraints.** Only an empirical run of the full apply + suite under the reduced set catches "binary present, but the deployed config demands a capability it lacks."

### Guarding the result

The minimal set is pinned by fast template tests so a broken guard fails **before** any package installs:

- `tests/bashunit/templates_test.sh` (render-mode block) — : minimal render asserts exactly the needed entries and refutes the guarded ones (`assert_minimal_brewfile`, `:352-367`); empty/unset/legacy-config renders stay full (`:391`, `:408`, `:435`); `MMS_CI_MINIMAL=0` is non-empty and therefore minimal (`:424`); init-time binding persistence (`:455`), hash-trigger include integrity (`:494`, `:513`), and empty-not-absent `Brewfile.macos` (`:533`, the PR #27 fix).
- The comment above `assert_minimal_brewfile` (`tests/bashunit/templates_test.sh:322-337`) states the honesty rule: "Every one of these is here because removing it broke something observable."
- Helpers: `write_test_config()` (`tests/helpers/common.bash:180`) renders the init-time config via `execute-template --init` (no side effects, works against the read-only Docker mount), and `render_with_config()` (`:123-129`) renders a template against that specific config — needed because `ci_minimal` binds at `chezmoi init` time, not render time.
- The template branch itself: `home/private_dot_config/brewfiles/Brewfile.tmpl:19` — `{{ $full := not (get . "ci_minimal") }}`, using `get` so configs generated before the key existed render full instead of aborting.
- **Test the deployment, not only the render** (session history): the minimal render made `Brewfile.macos` 0 bytes, and chezmoi does not deploy a file whose template renders empty unless the source carries the `empty_` attribute prefix — so the macOS job failed with "No Brewfile found" while every render-level test stayed green. The PR #27 fix renamed the source to `empty_Brewfile.macos.tmpl` and added a deployment-level regression test, verified by mutation (removing `empty_` reproduces the failure).

## Why This Matters

- **Green is not coverage.** Conditional skips convert "dependency missing" into "test not run, exit 0". Under an environment reduction, the suite's exit code measures nothing about sufficiency — dozens of this repo's tests could have vanished from coverage with a fully green run.
- **Static audits have a blind spot with a specific shape.** "Does the binary exist" is checkable by grep; "does the binary's *version* accept the *deployed configuration*" is only checkable by running the deployment. The git/zdiff3 failure is the canonical instance: the audit's classification was reasonable and wrong, and the parity gate — designed for a different failure mode (silent skip inflation) — is what caught it, because it required an empirical run at all.
- **The fold-back rule removes negotiation.** With "absence changes the skip set → package returns" as a mechanical stop condition, the minimal set stays honest without anyone arguing about whether a dependency is "probably fine".

## When to Apply

Any time an environment under a test suite gets **reduced**:

- Minimal CI images / installing only the packages a workflow uses (this case).
- Dependency pruning in a package manifest.
- Container slimming (removing apt/apk packages from a base image).
- Dropping "unused" system tools from a dev-environment bootstrap.

And in any suite with **conditional skips**: bats/bashunit `skip`, pytest `skipif`/`importorskip`, jest `test.skip`/`describe.skip`, Go `t.Skip`. The proof obligation is always "**the same tests ran**", not "the suite is green":

1. Run the suite under full and reduced environments.
2. Diff the skip sets (with reasons), not just counts — and count skipped *tests*, not skip *sites*.
3. Treat any delta as "the reduction removed coverage" → restore the dependency or explicitly accept the coverage loss.
4. Run the *whole deployment path* (here: `chezmoi apply`), not just the tests — config-compatibility failures surface before the first test.

Do **not** substitute a required-binary manifest for the empirical run: KTD6 records that option as rejected because it duplicates the candidate list in a second place that drifts (`docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md:84`).

## Examples

**The parity table as recorded** (`docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md:185-188`):

| Render | ok | not ok | skipped |
|---|---|---|---|
| `MMS_CI_MINIMAL=1` | 367 | 1 | 15 |
| unset | 367 | 1 | 15 |

Skip sets identical line for line; the one failure identical and pre-existing in both. The minimal `brew bundle` installed 4 packages vs 37 for the full render (`:192`).

**The audit miss, end to end:**

- Config: `home/dot_gitconfig.tmpl:27` — `conflictStyle = zdiff3` (git >= 2.35).
- Failure: apply aborts in ~57s on ubuntu:22.04's git 2.34.1, before any test (`docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md:154`).
- Fix 1 (PR #26, `1e4ea73`): fold `git` back into the minimal Brewfile.
- Fix 2 (PR #27, `f83e95d`): `docker/Dockerfile.ubuntu` → `FROM ubuntu:24.04` (git 2.43.0), with the rationale in the header comment.

**The git fold-back has since been reversed, and the reversal is itself asserted.** Once the base
image moved to ubuntu:24.04 the premise disappeared, so `brew "git"` went back inside the `{{ if $full }}`
block and the minimal render now *refutes* it. `tests/bashunit/templates_test.sh:326-331` states why in
the code:

> git was on that list and is not any more. The deployed .gitconfig sets `merge.conflictStyle = zdiff3`,
> which needs git >= 2.35, and Ubuntu 22.04's apt git was 2.34.1 — so Homebrew's git was the only one
> that could read the config inside the image. `docker/Dockerfile.ubuntu` now builds on 24.04, whose apt
> git is 2.43.0, so the claim no longer holds. It is refuted below rather than left unasserted, or a
> later fold-back passes silently.

That last clause is the durable lesson, and it is stronger than the fold-back it replaced: when a
dependency leaves the minimal set, assert its *absence* rather than dropping the assertion, so a
silent re-add cannot pass.

**The regression guard:** `assert_minimal_brewfile` in `tests/bashunit/templates_test.sh:338-357`
asserts the evidence-backed entries — currently the `oven-sh/bun` tap, `node`, `oven-sh/bun/bun`,
`jq`, and `gitleaks` — and refutes the guarded ones, with the per-entry evidence in the comment at
`:322-337`. `grc`, named in earlier revisions of this document, was removed from the repository
entirely.

## Related

- Plan: `docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md` — KTD6 (`:84`), R7 (`:57`), U1 outcome incl. git fold-back (`:140-158`), U2 verification outcome (`:183-194`).
- PRs: #26 (`1e4ea73`, the minimal-render mechanism + parity proof), #27 (`f83e95d`, empty `Brewfile.macos` deploy + ubuntu:24.04 base). Both on `main`.
- `2026-08-21-009` — closed 2026-08-21: one `setup()` skip guard silenced every test in the palette suite; found by the parity gate, invisible to ordinary CI. Resolved with a documented deliberate exception — `tests/bashunit/palette_test.sh:22` now states that python3 is a declared requirement whose absence must fail rather than skip.
- `2026-08-21-010` — closed 2026-08-21: `grc` survived only as the accidental python3 carrier — a second face of "the declared dependency set is not the one holding the suite up".
- `2026-08-21-007` — closed 2026-08-22: the inverse miss — 37 installed brew packages no test can reach because the prefix never lands on PATH.
- `2026-08-21-008` — done: ceilings recalibrated to 12 min (ubuntu) / 20 min (macos) from 9 days of post-minimal-install run data; the deliberate separate-change delay kept the timeout failure attributable.
- `completion-is-not-a-verdict.md` — same family, one layer up: there the runner's completion mark hid a red verdict from the human; here the suite's green hides which tests ran from everyone.
- `external-review-legs-as-unreliable-subprocesses.md` — same family, machine-side: a step that dies quietly must not read as a clean pass; a test that skips quietly must not read as a passing test.
- Known pre-existing failure the parity run had to reason around: `2026-08-19-001`.
- Closed issues above are bare IDs, for archaeology in git history: `2026-08-19-001`, `2026-08-21-007`,
  `2026-08-21-008`, `2026-08-21-009`, `2026-08-21-010`. All five files were removed in the closed-issue
  cleanup; the evidence they carried is reproduced inline above.
