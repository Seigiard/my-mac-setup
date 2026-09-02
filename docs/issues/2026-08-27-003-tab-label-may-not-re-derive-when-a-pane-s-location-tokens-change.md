---
title: "Tab label may not re-derive when a pane's location tokens change"
short_description: "A live probe overrode a pane's git_ref token without the composed tab label following within the observation window, so a token-only location fix may leave the tab row stale."
type: "follow-up"
category: "herdr"
tags: ["herdr-task-sync","labels","worktree"]
date: "2026-08-27"
status: "done"
priority: "low"
closed: "2026-08-28"
---

## Why this exists

Pane location tokens and tab labels are produced by different passes: the location pass publishes repo, worktree, branch and git_ref per pane, while compose_tab_intents builds each tab label from its panes' labels (home/dot_local/bin/executable_herdr-task-sync). During the live probe recorded in 2026-08-22-001, overriding a pane's git_ref did not change the label returned by herdr tab list inside the observation window. That probe was short and inconclusive, and no test covers the question. If the tab label does not re-derive, an agent that moves into a worktree now shows the right sidebar row and a stale tab row, which is the same confusion the original bug caused, moved one level up.

## Scope

Determine whether a composed tab label re-derives after only its panes' location tokens change, using a longer observation window than the original probe. If it does not, decide whether that is intended (tab labels deliberately carry no git information, per the config comment on the sidebar rows) or a defect, and cover the answer with a test either way. Out of scope: adding git information to tab labels, which the label system deliberately excludes.

## Open decisions

None.

## Resolution

Confirmed as intended names-only behavior: Git location changes update pane metadata without renaming the tab. The existing focused Bats regression test covers this contract and passed on 2026-08-28.
