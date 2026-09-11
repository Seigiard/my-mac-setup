---
title: "Deepen herdr-worktree state record ownership"
short_description: "Move the durable identity record schema, compatibility translation, and atomic named-field updates into herdr-worktree-state.sh without changing worktree outcomes or marker authorization."
type: "follow-up"
category: "herdr"
tags: ["architecture","worktree-identity","semantic-tests","enhancement","ready-for-agent"]
date: "2026-09-11"
status: "done"
priority: "high"
closed: "2026-09-11"
---

## Why this exists

The state module owns outcome names and storage primitives, while the 1,057-line executable still assembles the full record at 21 write sites and tests manually reproduce its encoding.

## Scope

Give the existing state module one named-field atomic write interface that preserves unspecified fields and old attribution_failed records; keep Git mutation, Generated-worktree marker authorization, and outcome selection in the executable. Route tests through the interface except for one legacy-format fixture.

## Open decisions

None. Compatibility, seam placement, and test-surface decisions were accepted during the architecture review.

## Resolution

Moved durable identity record ownership into herdr-worktree-state.sh with named-field updates, compatibility translation, and semantic coverage; verified the deployed checkout with make test-ubuntu.
