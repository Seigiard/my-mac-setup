---
title: "Vacuous assertions across five suites protect nothing"
short_description: "Nine assertion sites in scripts_test.sh, smoke_test.sh, idempotent_test.sh, test_docker_contract.py and three Smithers TS files cannot fail as written — a comment-only assertIn, a status-less refute_output, constant arithmetic, self-comparison and an unreachable predicate — so each reads as coverage while protecting no behavior."
type: "bug"
category: "testing-ci"
tags: ["tautological-tests","vacuous-assertions","test-quality"]
date: "2026-08-29"
status: "in-progress"
priority: "high"
---

## Why this exists

A 2026-08-29 audit of all 39 test files (~1014 tests) found nine assertion sites that
cannot change verdict when the behavior they name breaks. Unlike a tautological test,
which at least pins a real literal and costs only churn, these carry the cost of
appearing to protect something. Four were reproduced directly rather than read.

Verified by direct reproduction:

- `tests/test_docker_contract.py:35` — `assertIn("tests/bashunit/idempotent_test.sh", self.compose)`
  matches only comment text. Both occurrences in `docker/docker-compose.yml` are on
  comment lines 26 and 29; no service command references the file. Removing the
  idempotent suite from the run path leaves this green, while editing a comment reddens it.
- `tests/bashunit/smoke_test.sh:1038-1039` — `width` is asserted `-eq 32` on the line
  above, so `[ $((width - 4)) -ge 28 ]` evaluates `28 -ge 28` and the next line `28 -ge 8`.
  Both are arithmetic over a constant.
- `tests/bashunit/scripts_test.sh:161` — `run "$CHEZMOI_BIN" managed` is followed only by
  `refute_output --partial`, with no `assert_success`. A failing command emits an error
  string that satisfies the refutation.
- `tests/bashunit/scripts_test.sh:6065-6066` — `run cat "$HTS_LOG"` with no status
  assertion. The test is green when the sweep made zero calls and equally green when the
  log does not exist, because cat's stderr becomes `$output`.

Reported by audit, not individually reproduced:

- `tests/bashunit/idempotent_test.sh:142` — the workstation branch asserts
  `verdict != misconfigured` under the exact condition (`GITHUB_ACTIONS` unset and no
  `/.dockerenv`) that makes `mms_disposable_home_verdict` structurally incapable of
  returning `misconfigured`. The file's own header claims this test keeps it from being
  inert locally.
- `home/private_dot_claude/dot_smithers/workflows/lib/gates.test.ts:427` and `:441` — both
  push into `verdict.reasons` themselves and then assert on the result; `:441` asserts
  `Array.prototype.push`. The real call site, `se-pipeline.tsx:684`, has no coverage.
- `home/private_dot_claude/dot_smithers/workflows/lib/block-registry.test.ts:77` and
  `blocks/index.test.ts:17` — "byte-stable across generations" compares one object to
  itself, so `catalogToJson`'s `sortedReplacer()` is never exercised.
- `tests/bashunit/templates_test.sh:37` — `chezmoi data` reads the host's bound config, so
  the test's exported `CHEZMOI_NAME` is inert; on Linux the asserted substring `"name"`
  comes from `.chezmoi.osRelease.name` regardless of the config key.

## Scope

Replace each site with an assertion that changes verdict when the named behavior breaks:

- `test_docker_contract.py:35` — drop the compose-text check; reachability is already
  proven behaviorally by `tests/test_post_apply_suite_contract.py`, which runs the wrapper
  and observes `idempotent_test.sh` in `full` mode's argv but not in `host-safe`'s.
- `smoke_test.sh:1038-1039` — delete both lines, or derive the width budget from the
  consumer (`~/.local/bin/herdr-task-sync`) instead of restating the constant.
- `scripts_test.sh:161` — add `assert_success`, plus a positive control proving the listing
  is non-empty and OS-filtered before the refutation.
- `scripts_test.sh:6065-6066` — assert the sweep ran (`assert_file_contains "$HTS_LOG"
  '^api snapshot$'`), then use `run grep -c -E '^(pane|tab) rename' "$HTS_LOG"` with
  `assert_output "0"`, which distinguishes "no rename" from "no log".
- `idempotent_test.sh:142` — assert the pair instead: unmarked yields `skip`, and setting
  the marker flips it to `run`. Keep the CI/docker branch unchanged.
- `gates.test.ts:427`/`:441` — assert `mainCheckoutEscapeReason`'s own output, and extract
  the `se-pipeline.tsx:684` composition into a testable exported function.
- `block-registry.test.ts:77`, `blocks/index.test.ts:17` — build two independently
  registered registries and compare their JSON, which is what the test name already claims.
- `templates_test.sh:37` — bind the env var at init time via the existing
  `write_test_config` helper, and add a control asserting a different value renders
  differently.

Run `make test-suite` for the host-safe files and `make test-ubuntu` for the full Docker
suite; Smithers changes use `make test-smithers`.

## Open decisions

Whether `smoke_test.sh:1038-1039` protects a real constraint worth deriving, or should
simply be deleted. No consumer of the width budget has been identified yet.
