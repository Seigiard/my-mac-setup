---
title: "Peer report transport accepts a symlinked report file"
short_description: "The shared herdr peer lifecycle validated the peer report with [ -f ] and [ -s ], which follow symlinks, so a peer that left a symlink at claude.report or opencode.report made the review silently synthesize whatever that link targeted; the acceptance test now rejects -L before opening the path and treats it as a terminal malformed delivery, matching classify_report in ask.sh."
type: "follow-up"
category: "agent-platform"
tags: ["report-transport","herdr-peer-launch","coherence-guard"]
date: "2026-09-03"
status: "done"
priority: "low"
closed: "2026-09-03"
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

None. The shared lifecycle keeps collapsing missing and empty into one recovery
attempt: unlike `ask.sh` it has no exit code to report the difference through,
and both are answered by the same recovery prompt.

## Resolution

The shared herdr peer lifecycle now refuses a symlinked report path without opening it. report_is_delivered rejects -L before the -f and -s tests, and recover_peer_report treats that rejection as terminal rather than sending a recovery prompt, so a malformed delivery is never retried as a missing one. This matches classify_report in ask.sh. The open decision was settled the other way: the shared lifecycle keeps collapsing missing and empty into one recovery attempt, because unlike ask.sh it has no distinct exit code to report the difference through.
