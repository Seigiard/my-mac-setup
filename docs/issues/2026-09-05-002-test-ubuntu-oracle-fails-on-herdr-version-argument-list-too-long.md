---
title: "test-ubuntu oracle fails on herdr --version argument-list-too-long"
short_description: "make test-ubuntu deterministically fails 2 templates_test.sh assertions (zshenv host-partial diff and skip-secrets cases) because chezmoi's output template function execs /home/linuxbrew/.linuxbrew/bin/herdr --version via run_onchange_after_3-setup-herdr-integrations.sh.tmpl:10 and hits an OS argument-list-too-long error; reproduced identically across a plan's diff present/absent and a --no-cache image rebuild, so it is environment/harness-level (suspected: bashunit's exported shell functions bloating the inherited env past ARG_MAX under nested env/chezmoi-diff calls), not a code regression, and it currently blocks the make test-ubuntu deployment-sensitive gate for every PR."
type: "bug"
category: "testing-ci"
tags: ["test-ubuntu","chezmoi","herdr","argument-list-too-long"]
date: "2026-09-05"
status: "open"
priority: "high"
---

## Why this exists

Discovered while running `docs/plans/2026-09-05-0906-refactor-mise-declarative-setup-plan.md`'s
U2 verification. `make test-ubuntu` fails with 2 failed assertions in
`tests/bashunit/templates_test.sh`, both in the `zshenv` test cases around
lines 220-308 (`test_templates_0092_zshenv_host_partial_diff_preserves_secret_target_and_reports_work`
and `test_templates_0094_zshenv_skip_secrets_omits_state_but_execute_template_fails`).
Both invoke a full-tree `chezmoi diff` / `execute-template` through
`tests/helpers/chezmoi-unattended` with a sandboxed `HOME`, which touches
every `run_onchange` script including
`home/.chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl:10`.
That script's hash-trigger comment calls chezmoi's `output "herdr" "--version"`
template function, which fails:

```
chezmoi: .chezmoiscripts/3-setup-herdr-integrations.sh: template: .chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl:10:45: executing ".chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl" at <output "herdr" "--version">: error calling output: /home/linuxbrew/.linuxbrew/bin/herdr --version: fork/exec /home/linuxbrew/.linuxbrew/bin/herdr: argument list too long
```

The main `chezmoi apply --verbose` step inside the same `test-ubuntu` run does
**not** hit this — only the templates_test.sh invocations through the
sandboxed-`HOME` launcher do. This blocks the `make test-ubuntu`
deployment-sensitive verification gate (`docs/agent-verification.md`) for
every PR that touches a managed path, including plan 2026-09-05-0906's U1
(already committed) and U2/U3 (in progress).

**Isolation performed** (4/4 reproductions, identical failure and location
each time):

- With plan 2026-09-05-0906's U2 diff applied (`.chezmoiexternal.toml`,
  `run_onchange_after_1-install-packages.sh.tmpl`, `dot_zshrc.tmpl`,
  `dot_aliases`, `tests/bashunit/scripts_test.sh`).
- With that diff `git stash`ed back to just the plan's already-committed U1
  state (mise config only) — rules out this plan's changes as the cause.
- After a full `docker compose build --no-cache test-ubuntu` — rules out a
  stale/corrupted Docker image layer as the cause.

**Suspected root cause** (not confirmed — a hypothesis for whoever picks this
up): `tests/lib/bashunit -j 8` runs with parallel workers and the framework
exports many shell functions (`export -f`) into the environment for its
assertion helpers. That environment is inherited through the nested
`run env HOME=... MMS_CHEZMOI_UNATTENDED=1 tests/helpers/chezmoi-unattended
--profile host-partial -- diff ...` invocation down to chezmoi's own
`output "herdr" "--version"` subprocess exec, plausibly pushing combined
argv+envp past the Linux `ARG_MAX` limit. The identical failure under a
freshly rebuilt image argues against anything baked into the Docker image
itself.

## Scope

- Confirm the actual cause (start by measuring the environment size at the
  point of the failing `output` call, e.g. temporarily wrapping `herdr` or
  adding diagnostic output to the failing test's `run env ...` invocation).
- Either shrink the inherited environment before the nested `chezmoi diff`
  call in `tests/helpers/chezmoi-unattended`, or make the hash-trigger call
  in `run_onchange_after_3-setup-herdr-integrations.sh.tmpl` resilient to a
  large ambient environment (e.g., invoke `herdr --version` with a trimmed
  `env`).
- Re-run `make test-ubuntu` and `tests/lib/bashunit -j 8 tests/bashunit/templates_test.sh`
  to confirm both previously failing assertions pass.

## Open decisions

- Whether the fix belongs in the test harness (`tests/helpers/chezmoi-unattended`)
  or in the affected run script itself — depends on which side is confirmed
  as the actual source of the oversized environment.
