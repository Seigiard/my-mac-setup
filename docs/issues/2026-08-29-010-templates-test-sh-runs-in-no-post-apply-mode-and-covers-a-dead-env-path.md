---
title: "templates_test.sh runs in no post-apply mode and covers a dead env path"
short_description: "run-post-apply.sh runs smoke, scripts, palette, platform and idempotent but never templates_test.sh, which reaches CI only through make test-templates where the config name comes from chezmoi init --promptString — so the CHEZMOI_NAME and CHEZMOI_EMAIL env path those tests claim to cover is exercised nowhere."
type: "bug"
category: "testing-ci"
tags: ["test-coverage","templates","chezmoi"]
date: "2026-08-29"
status: "done"
priority: "medium"
closed: "2026-08-30"
---

## Why this exists

`tests/run-post-apply.sh` runs `smoke scripts palette platform idempotent`. It never runs
`tests/bashunit/templates_test.sh`, so neither `make test-suite` nor the full Docker suite's
post-apply stage exercises the template tests. They reach CI only through
`make test-templates`.

In that one environment the chezmoi config is created by `chezmoi init` with
`--promptString name="Test User" email="test@example.com"`, so the config values come from
the prompt, not from the environment. The consequence is that the `CHEZMOI_NAME` and
`CHEZMOI_EMAIL` path that tests 002 and 003 claim to cover is exercised in no environment
at all.

Test 002 (`templates_test.sh:37`) is separately vacuous and is tracked in
`2026-08-29-006-vacuous-assertions-across-five-suites-protect-nothing`: `chezmoi data` reads
the host's already-bound config, so its exported env var is inert, and on Linux the asserted
substring `"name"` is supplied by `.chezmoi.osRelease.name` regardless of the config key.
This issue owns the wiring gap; that one owns the assertion.

A related mirroring cluster lives in the same file and is worth fixing in the same pass:
tests 005 and 006 (`:61`, `:67`) assert the literals `"name = "` and `"email = "`, which are
unconditional boilerplate at `home/dot_gitconfig.tmpl:2-3` — the substitution of `.name` and
`.email` into git's `[user]` section is the one thing worth asserting and the one thing not
asserted. Tests 012 and 014 (`:227`, `:254`) assert literals from `opencode.json.tmpl`, a
file containing zero template directives.

## Scope

- Decide whether `templates_test.sh` should join a `run-post-apply.sh` mode or stay a
  separate `make test-templates` target, and make the chosen wiring explicit.
- Give the env-var path real coverage by binding `CHEZMOI_NAME` and `CHEZMOI_EMAIL` at init
  time through the existing `write_test_config` helper, with a control asserting that a
  different env value renders a different config value.
- Assert rendered substitutions rather than static keys in tests 005 and 006: compare the
  rendered `name = ` / `email = ` lines against the config's values and add
  `refute_output --partial '{{'` to catch an unrendered directive.
- For tests 012 and 014, either drop them in favour of the existing JSON-validity test 011,
  or convert them to a cross-artifact contract — assert that the `instructions` target file
  exists in the source tree, since a dangling path fails silently in OpenCode.

Verify with `make test-templates`, then `make test-ubuntu`.

## Open decisions

Whether `templates_test.sh` belongs in the post-apply suite at all. It asserts rendering
rather than deployed state, which is a different stage from what `run-post-apply.sh` covers,
so adding it may be the wrong fix and an explicit note in the runner may be the right one.

## Resolution

run-post-apply.sh now states explicitly that templates_test.sh is a pre-apply rendering gate wired through CI, docker-compose, and make test-templates — it stays out of both post-apply modes by design (the open decision resolved toward the explicit note). The dead CHEZMOI_NAME/CHEZMOI_EMAIL path got real coverage: tests 002/003 now bind the env vars at init time via write_test_config with two differing probe values each (control: a different env value produces a different config value). Tests 005/006 render dot_gitconfig.tmpl against a probe-value config and assert the substituted user.name/user.email lines plus refute any unrendered directive, instead of the unconditional 'name = ' boilerplate. Test 012's provider/plugin/model literal restatement was deleted as tautological; a narrowed 012 pins the two externally consumed security invariants (external_directory grant, stdio executor transport). Test 014 became a cross-artifact contract: every opencode instructions entry must resolve via chezmoi source-path to a managed source file. Every rewritten test was calibrated red with a production mutation and green after restore. Verified: make test-templates (Docker, green), make test-ubuntu (full Docker suite, exit 0), post-apply contract test, check_bats_assertions. This also implements the templates_test.sh item of issue 2026-08-29-006.
