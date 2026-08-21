---
title: python3 is treated as both required and optional in the same test suite, so a missing python3 hides 56 tests behind an unrelated red
type: bug
date: 2026-08-21
status: open
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
