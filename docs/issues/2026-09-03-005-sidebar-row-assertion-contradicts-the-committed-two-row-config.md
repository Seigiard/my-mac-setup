---
title: "Sidebar row assertion contradicts the committed two-row config"
short_description: "Smoke tests 1058 and 1059 failed on both the source and the deployed config because commit a25c20f moved the herdr sidebar to the intended two-row layout while assert_herdr_sidebar_deployment_contract still pinned the single-row arrangement; the helper now asserts the three identity fields and their order without pinning the row grouping."
type: "bug"
category: "testing-ci"
tags: ["smoke-test","herdr-sidebar","stale-assertion"]
date: "2026-09-03"
status: "done"
priority: "medium"
closed: "2026-09-03"
---

## Why this exists

`assert_herdr_sidebar_deployment_contract` in `tests/bashunit/smoke_test.sh:939` pins the
sidebar layout literally:

```
assert_file_contains "$config" 'rows = \[\["state_icon", "workspace", "pane"\]\]'
```

Commit a25c20f ("Update config.toml", 2026-09-03) changed
`home/private_dot_config/herdr/config.toml:63` to a two-row layout:

```
-rows = [["state_icon", "workspace", "pane"]]
+rows = [["state_icon", "workspace"], ["pane"]]
```

The assertion was not updated, so both callers of the shared helper fail:

- `test_smoke_1058` against the source tree `home/private_dot_config/herdr/config.toml`
- `test_smoke_1059` against the deployed `~/.config/herdr/config.toml`

Measured on 2026-09-03 with `tests/lib/bashunit -j 8 tests/bashunit/smoke_test.sh`:
47 passed, 2 failed. The two failures are exactly 1058 and 1059, and both name the same
regex. Nothing else in the suite touches the sidebar row layout.

Impact is a persistently red smoke suite, which masks a real regression the same helper
would otherwise catch: the helper also guards the codicon octal escapes and the
ownership boundaries, and a reader who has learned to expect two failures stops reading
the rest.

## Scope

Decide which layout is intended, then make the config and the assertion agree.

- If the two-row layout is intended, relax or re-pin the assertion to it. The assertion
  is a source-shape pin with no behavioral oracle, so consider whether it should assert
  the presence of the three fields rather than one exact arrangement.
- If the single-row layout is intended, revert the config line.

Either way, run `tests/lib/bashunit -j 8 tests/bashunit/smoke_test.sh` and confirm 49
passed, 0 failed.

## Open decisions

None. The owner confirmed the two-row layout is correct, and the exact-string pin was
relaxed for the same reason: the row grouping is a presentation preference, not a
contract.

## Resolution

The two-row layout is the intended one. assert_herdr_sidebar_deployment_contract now asserts that the rows declaration carries state_icon, workspace, and pane in that order without pinning how they are grouped into rows, and the verbatim duplicate of the same pin later in the helper was removed. The sidebar's real guard against location metadata stays: the adjacent grep for $git_ref, $location_label, and $location_status still asserts failure. tests/bashunit/smoke_test.sh now reports 49 passed, 0 failed.
