---
title: "Pane-label herdr stub omits four snapshot keys the real binary returns"
short_description: "The stub's .result.snapshot omits focused_pane_id, focused_tab_id, focused_workspace_id and version that real herdr 0.8.2 returns, while conformance test 1209 pins only the top-level result keys; widening was deliberately deferred because the pane-label engine reads none of the four, and an honest widening would couple the suite to a herdr version."
type: "follow-up"
category: "testing-ci"
tags: ["herdr","semantic-tests","test-integrity"]
date: "2026-09-05"
status: "open"
priority: "low"
---

## Why this exists

PR #179 added `tests/bashunit/scripts_test.sh` test 1209, which compares the stub
herdr's `api snapshot` envelope against the installed binary. It was deliberately scoped to the
**top-level `result` keys**, because anything below that belongs to herdr and restating it locally
would reimplement upstream semantics — the failure mode that issue exists to avoid.

At that scoped level the stub is correct: both sides return `["snapshot","type"]`.

One level down they diverge. Measured against herdr 0.8.2 on macOS on 2026-09-05:

```sh
herdr api snapshot | jq -S -c '.result.snapshot | keys'
```

real:  `agents, focused_pane_id, focused_tab_id, focused_workspace_id, layouts, panes, protocol, tabs, version, workspaces`
stub:  `agents, layouts, panes, protocol, tabs, workspaces`

The stub omits `focused_pane_id`, `focused_tab_id`, `focused_workspace_id`, and `version`. Its
snapshot skeleton is assembled by `jq` in `tests/helpers/herdr_pane_labels.bash`.

**This is latent, not a live bug.** `home/dot_local/bin/executable_herdr-pane-labels` reads none
of the four — `grep` for `focused_` and `.version` in the engine is empty — so no current
assertion is wrong. It becomes live the moment the engine starts using focus information, and at
that point every pane-label test would keep passing against a stub that cannot supply it.

This is the same drift class `docs/solutions/design-patterns/fakes-need-the-real-binary-as-oracle.md`
documents, where PR #115 had to correct the
stub's sequence comparison by hand because no test compared the fake to the real binary.

## Scope

- Decide whether the stub should carry the four keys, and if so whether they hold real values or
  inert placeholders.
- Whatever is decided, keep the upstream-ownership rule: do not grow a local assertion that
  encodes what herdr's snapshot *should* contain. If the stub gains the keys, the thing that keeps
  it honest is a comparison against the real binary, not a hand-written expectation.
- Note that widening test 1209 to compare the `snapshot` key set would be red today, and would
  couple the suite to a herdr version. Any widening needs a skip-if-mismatched-version story, or
  it will fail on the next herdr release for a reason that is not a defect.

## Open decisions

- Whether to widen the stub at all before the engine needs focus information. Adding keys nothing
  reads has its own cost, and the honest alternative is to leave this recorded and act when a
  consumer appears.
- If the stub is widened, whether test 1209 grows to cover the deeper key set or a separate check
  owns it.

## Decision (2026-09-06): deferred until a consumer exists

Do not widen the stub yet. Re-measured against herdr 0.8.2 today: the real `herdr api snapshot`
returns all four keys with real values, and `home/dot_local/bin/executable_herdr-pane-labels` reads
none of them — it calls the snapshot at exactly one site and every downstream read touches only
`panes`, `tabs`, `agents` and `workspaces`.

The reason to wait is not the four `jq` lines. Widening the stub honestly means test 1209 must
compare the deeper key set against the real binary, which couples the suite to herdr 0.8.2 and needs
a skip-on-version-mismatch story. Paying that for keys nothing reads is premature.

Reopen the question the moment engine code reads focus or version — at that point the stub cannot
supply what the code needs, and every pane-label test would pass green against a fake that is
missing the field under test.

### Re-verified 2026-09-07: deferral still correct

Re-measured against the same herdr 0.8.2 (`/opt/homebrew/bin/herdr`). The divergence is unchanged in
both directions:

```
real - stub = focused_pane_id, focused_tab_id, focused_workspace_id, version
stub - real = (empty)
common      = agents, layouts, panes, protocol, tabs, workspaces
```

The stub's six keys are assembled at `tests/helpers/herdr_pane_labels.bash:279`; its
incomplete-snapshot branch at line 281 is narrower still (`protocol`, `panes`), by design.
`git log -S focused_pane_id` over the engine and the stub helper returns zero commits across the whole
history, so the reopen trigger has not fired.

**One clarification for whoever greps next.** `home/private_dot_config/herdr/plugins/command-palette/open.py:45`
does read `focused_pane_id` — but from `HERDR_PLUGIN_CONTEXT_JSON`, the plugin-context environment
channel, not from `api snapshot`. It never touches the pane-label stub and is **not** the consumer that
triggers the reopen. A bare `grep focused_` across the repository will surface it; do not mistake it for
engine code adopting focus information.

The three real snapshot consumers remain clean: `home/dot_local/bin/executable_herdr-pane-labels:1048`
(the single `api snapshot` call site), `home/dot_local/bin/executable_herdr-worktree-identity:376`, and
`home/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh`. None reads any of the four keys; no file in
the repository reads `.result.snapshot.version`.
