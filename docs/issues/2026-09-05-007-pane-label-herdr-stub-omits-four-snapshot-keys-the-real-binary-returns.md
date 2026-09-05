---
title: "Pane-label herdr stub omits four snapshot keys the real binary returns"
short_description: "The new conformance check (scripts_test.sh test 1209) pins only the top-level result keys, and one level down the stub's .result.snapshot omits focused_pane_id, focused_tab_id, focused_workspace_id and version that real herdr 0.8.2 returns; the engine reads none of them today, so the drift is latent rather than a live bug."
type: "follow-up"
category: "testing-ci"
tags: ["herdr","semantic-tests","test-integrity"]
date: "2026-09-05"
status: "open"
priority: "low"
---

## Why this exists

`2026-09-02-012` added `tests/bashunit/scripts_test.sh` test 1209, which compares the stub
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

This is the same drift class `2026-09-02-012` documented, where `d080d31` had to correct the
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
