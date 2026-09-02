---
title: "Remove source-mirror assertions with stronger behavioral owners"
short_description: "The herdr-child module inventory inside scripts_test.sh test 269 duplicates coverage that command-level lifecycle tests already own, while the Pi package assertion in smoke_test.sh has drifted two packages behind the modifier and still needs a deployment owner decision."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-testing","duplicate-coverage","source-ownership"]
date: "2026-09-01"
status: "open"
priority: "medium"
---

## Why this exists

The repository-wide tautological-test audit identified assertions that can be deleted without losing an independently observable verdict.

`tests/bashunit/scripts_test.sh:7657-7813` (test 269, `herdr-child modules load in order without source-time effects`) hardcodes the herdr-child module source order, the exact function set each module owns, and the exact globals each module initializes, even though command-level lifecycle tests already exercise launch, supervision, continuation, and reap behavior. Those three inventories are copied from the implementation they guard: they fail on a harmless module rename or helper extraction and stay green when the commands themselves break.

`tests/bashunit/smoke_test.sh:404-418` (test 16, `pi settings include all managed packages`) asserts a package list that has already drifted: it names 7 packages while `home/dot_pi/agent/modify_settings.json` declares 9, omitting `npm:pi-ask-user` and `git:github.com/EveryInc/compound-engineering-plugin`.

## Scope

Remove the source-order, function-ownership, and global-ownership comparisons from test 269 while retaining the sourceability, no-output, shell-state, function-redefinition, and global-mutation checks that live in the same test body (`tests/bashunit/scripts_test.sh:7724-7790`). This is an edit inside one test function, not a deletion of the test.

Resolve the Pi package assertion in `smoke_test.sh` according to the open decision below. The Pi settings modifier transformation and its idempotency are owned by `tests/bashunit/scripts_test.sh:7039-7090` (tests 250 and 251); the smoke assertion is a different owner and covers the deployed `~/.pi/agent/settings.json` rather than the modifier transform.

Run the narrow shell suites and confirm each deleted assertion had no distinct consumer or failure mode.

## Open decisions

- Whether the Pi package assertion in `smoke_test.sh` should be deleted as a duplicate or repaired as the deployment owner. The modifier tests prove the stdin-to-stdout transform; only the smoke test proves the packages reached the applied `~/.pi/agent/settings.json`, and `CLAUDE.md` reserves the smoke suite for exactly that deployed cross-component behavior. Deleting it therefore removes the only delivery evidence. The default is to keep the assertion and fix the drift, deriving the expected package set from the deployed settings' independent consumer rather than restating a hand-maintained list.
- If implementation reveals an externally consumed module or package-membership contract not covered by the retained owners, stop and move that assertion under `2026-09-01-002` instead of deleting it.
