---
title: "Peer report transport accepts a symlinked report file"
short_description: "recover_peer_report in the shared herdr peer lifecycle validates the peer report with [ -f ] and [ -s ], which follow symlinks, so a peer that leaves a symlink at claude.report or opencode.report makes the review silently synthesize whatever that link targets; ask.sh gained an explicit -L rejection reported as bad-report with exit 5 for the same class of coherence failure, and the shared lifecycle should match it."
type: "follow-up"
category: "agent-platform"
tags: ["report-transport","herdr-peer-launch","coherence-guard"]
date: "2026-09-03"
status: "open"
priority: "low"
---

## Why this exists

`recover_peer_report` in `home/private_dot_claude/shared/herdr-peer-launch.md:126-135`
decides whether a peer delivered its report with two tests:

```
[ -f "$report_path" ] && [ -s "$report_path" ] && return 0
```

Both follow symlinks. A peer that writes a symlink at `claude.report` or
`opencode.report` instead of a file passes, and the caller then reads and
synthesizes the link's target. The peer picks the target, so the review can
silently ingest an unrelated file the user can read, attributed to that peer.

`ask-in-herdr` now rejects the same shape explicitly. `classify_report` in
`home/private_dot_agents/skills/ask-in-herdr/scripts/executable_ask.sh` tests
`[ ! -L "$report_path" ]` first and reports `bad-report` with exit 5 without
ever opening the path. The two transports otherwise agree: both `mktemp -d` a
`chmod 700` directory, both instruct a `.tmp` write plus rename, and both make
exactly one bounded recovery request before giving up.

This is a coherence guard, not a containment boundary. A peer runs as the same
user and can read those files directly, so the guard buys an honest failure
rather than a silently wrong review, exactly as it does in `ask.sh`.

Impact is low: no occurrence has been observed, and every peer in use today
writes a regular file. It is filed because the two transports should not
disagree about what counts as a delivered report.

## Scope

Bring the shared lifecycle's acceptance test in line with `classify_report`:
reject a symlink and a non-regular file before reading, and report that
rejection distinctly from "missing" and "empty" so a malformed peer is not
retried as if it had simply not answered yet.

`se-code-review`, `se-doc-review`, and `se-simplify` delegate the whole
transport to this lifecycle and name no path of their own, so they need no
change.

## Open decisions

- Whether the shared lifecycle should also distinguish empty from missing the
  way `ask.sh` does, or keep collapsing both into one recovery attempt.
