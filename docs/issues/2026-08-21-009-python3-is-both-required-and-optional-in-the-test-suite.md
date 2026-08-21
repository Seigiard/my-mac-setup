---
title: python3 is treated as both required and optional in the same test suite, so a missing python3 hides 56 tests behind an unrelated red
type: bug
date: 2026-08-21
status: done
closed: 2026-08-21
---

## Why this exists

The bats suite carries two contradictory policies for `python3`, and the disagreement is
what makes a missing interpreter confusing rather than obvious.

| Site | Policy |
|---|---|
| `tests/palette.bats:14` | optional — `command_exists python3 \|\| skip "python3 not installed"` |
| `tests/smoke.bats:190, 206, 276, 524, 798, 838` | required — bare `run python3 …` followed by `assert_success` |
| `tests/scripts.bats:852` | required — same shape |
| `tests/scripts.bats:1789` | optional — `command -v python3 >/dev/null \|\| skip` |
| `tests/templates.bats:176, 266` | genuinely optional — one of three interchangeable JSON parsers (`jq` / `python3` / `node`) |

`python3` is therefore **required in practice**: without it `tests/smoke.bats` fails
regardless of what any guard does. That makes the `tests/palette.bats:14` guard unable to
save a run — it cannot prevent the failure, it can only change what the failure looks
like.

What it changes it into is the problem. That guard sits inside `setup()`, which bats runs
before **every** test in the file, so one skip site silences all **56** tests in
`tests/palette.bats`. The run then shows a handful of red tests in `smoke.bats` and a
quietly shortened suite elsewhere, and nothing connects the two. The reader debugs the
visible failure without noticing that a fifth of the suite stopped executing.

Found while writing the skip-count parity gate for
`docs/plans/2026-08-20-2217-perf-ci-minimal-brew-install-plan.md`. Note that the parity
gate does catch this — the skip counts diverge — but only when someone runs both renders
and compares. Ordinary CI does not.

For contrast, `sqlite3` is consistent and needs nothing: all seven guards plus the
unguarded calls inside the `se_fake_runtime()` helper (`tests/scripts.bats:4699`) are
reachable only from tests that guard on it.

## Scope

Decide one policy for `python3` and apply it at every site.

- **Required** — drop the `tests/palette.bats:14` guard, or replace it with an assertion
  that fails. Matches what `smoke.bats` already assumes. Costs a contributor without
  `python3` 56 red tests instead of 56 invisible skips — but they were already getting red
  from `smoke.bats`, so nothing actually degrades for them.
- **Optional** — add guards to the seven bare `run python3` sites so a missing interpreter
  skips consistently everywhere. Larger change, and it makes the suite quieter about a
  tool it genuinely depends on.

Leave `tests/templates.bats` alone either way: its `jq`/`python3`/`node` fallback is a
real three-way choice, not a policy inconsistency.

## Open decisions

- Required or optional? `smoke.bats` already behaves as if required, which is the cheaper
  direction to make consistent.
- Is there a case for a suite-wide "strict" switch — an environment variable that turns
  every tool guard into a hard failure in CI and Docker while leaving local runs
  skippable? That would fix this class of problem rather than this instance, but it is a
  larger change and touches every guard.
- Related: `docs/issues/2026-08-21-010-grc-is-vestigial-and-rgrc-was-never-moved-cross-platform.md`
  removes the package that currently supplies `python3` inside the Docker image. Whichever
  policy wins here, that issue's fix has to put `python3` in the image by another route
  first, or this becomes a live failure instead of a latent one.

## Resolution

**Required** won, applied at every site. Landed in `d4f571d` (pull request #28), planned in
`docs/plans/2026-08-21-0337-fix-python3-declared-dependency-plan.md`.

Both optional guards are gone — the `setup()` skip in `tests/palette.bats` and the in-test
skip in `tests/scripts.bats`. In their place, `tests/helpers/common.bash` gained
`assert_python3_available()`, called from a named first test in `tests/palette.bats`,
`tests/scripts.bats` and `tests/smoke.bats`. The third file lost no guard but holds eight of
the nine bare call sites, so a contributor running it alone still gets the cause named
rather than inferred. Each removal site carries a comment recording the deliberate exception
to the skip convention in
`docs/issues/2026-08-20-013-se-blocks-test-hard-fails-without-deps.md`.

The failure message names the interpreter, the version found, and the `README.md`
requirements section that now states the dependency with a 3.9 floor — measured, not
assumed: that is what macOS ships at `/usr/bin/python3`.

The ordering constraint this issue raised against
`docs/issues/2026-08-21-010-grc-is-vestigial-and-rgrc-was-never-moved-cross-platform.md` is
satisfied. `docker/Dockerfile.ubuntu` installs `python3` in its apt layer, so the image no
longer depends on `brew "grc"` for an interpreter. Measured in the rebuilt image before any
apply: `/usr/bin/python3` is 3.12.3, and the palette's own `--validate` exits 0 on it.

Counts after the change, with zero `python3` skips anywhere: `tests/palette.bats` 58,
`tests/scripts.bats` 195, `tests/smoke.bats` 71. The deliberate `internal descriptor probe`
skip at `tests/scripts.bats:1767` still reports, and the `jq`/`python3`/`node` fallback in
`tests/templates.bats` is untouched as this issue's Scope required.

Two open decisions were **not** taken here. The suite-wide strict switch is still unbuilt:
roughly ninety-eight guards for `jq`, `bun`, `sqlite3` and `zsh` keep their skips, because
the discriminator is not "declared" — those tools are declared too — but that this
repository does not install `python3` and a shipped feature invokes it during `chezmoi
apply` itself. Two follow-ups were filed from the code review of this work:
`docs/issues/2026-08-21-018-ci-minimal-docker-apply-has-no-automated-gate.md` and
`docs/issues/2026-08-21-019-python3-floor-is-stated-in-two-places-with-no-cross-check.md`.
