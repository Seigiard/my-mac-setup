---
title: "File-backed ask and reply payloads need a run-directory lifetime redesign first"
short_description: "Moving ask/reply message bodies onto the child's generation-scoped run directory is blocked by six defects a three-envelope review found: the watcher deletes the directory on marker delivery, attached children get no generation at all, `ask_parent` gates on a hardcoded `mode=detach`, `atomic_write` cannot preserve bytes, retirement has no owner that survives an unreaped pane, and nothing distinguishes a complete payload from a truncated one."
type: "follow-up"
category: "agent-platform"
tags: ["herdr-child","payload-transport","deferred"]
date: "2026-09-03"
status: "open"
priority: "medium"
---

## Why this exists

A plan to move all four inter-agent message bodies — task, ask, reply, report — onto the
child's `$STATE_DIR/runs/<generation>/` directory went through a three-envelope review
(six local personas, a fresh Claude peer, a fresh OpenCode peer, plus a cross-model pass
inside the Claude peer). The review returned one P0 and roughly fifteen P1 findings. The
report direction was split out and shipped separately on a caller-owned transport; the
ask/reply direction is blocked on the defects below.

Six blocking findings, each confirmed against the source:

1. **The watcher deletes the run directory on the delivery success path.**
   `herdr-child-watcher.sh:351-358` calls `remove_supervision_run` immediately after a
   marker is delivered, then exits. The parent is turn-based and its turn begins after
   `herdr agent prompt` returns, so a body placed there is unlinked inside that window.
   This is `docs/issues/2026-08-15-007` on the success path instead of an unlucky one.
2. **Attached children have no generation and no run directory.** The whole block is
   gated on `if [ "$mode" = detach ]` at `herdr-child-launch.sh:359`. `ask-in-herdr` is
   attached-only.
3. **`ask_parent` gates on a hardcoded detach mode.** It exits 1 with "detached child
   metadata is unavailable or inconsistent" unless `child_mode` is exactly `detach`
   (`herdr-child-continuation.sh:237-242`), and `write_launch_state`
   (`herdr-child-runtime.sh:156`) hardcodes `mode=detach`. Giving attached children a run
   directory without addressing this leaves them with a directory they cannot legally reach.
4. **`atomic_write` cannot carry a message body.** It is `printf '%s\n' "$content"` with a
   shell-string argument, so it always appends a newline and cannot round-trip bytes. It
   remains correct for the small state records it was built for.
5. **Retirement has no owner that survives an unreaped pane.** Handing teardown to `reap`
   fails because `reap_children` returns early once the pane is gone — the exact case where
   a body must still be readable. No sweep exists anywhere in `home/dot_local/lib/`.
6. **Nothing distinguishes a complete payload from a truncated one.** The marker carries
   identity coordinates, a path and a summary; none of that lets a reader tell a short
   valid body from a cut-off one, so a typed truncated status cannot fire.

## Scope

Decide whether ask and reply bodies need file transport at all, and if so, redesign
run-directory lifetime before any body is written there.

Secondary findings the same review raised, worth carrying into that work:

- A child's own exit trap can delete the run directory; moving the watcher's teardown does
  not constrain the child process.
- A payload written just before the writing child dies, with no marker ever delivered, has
  no defined outcome.
- Two attached asks in one exchange collide on a `generation`-plus-fixed-name path with no
  event component.
- Path-string validation does not prove the object is a regular file; a child that can write
  the directory can leave a symlink there.
- `[child-ask v1]` carries no event id, so two attached asks cannot be keyed or deduplicated.

Related: `docs/issues/2026-08-30-007` (abandoned `in-progress` callback claims poll forever)
and `docs/issues/2026-08-30-010` (which asks that the liveness, abandoned-callback and
pane-retry defects be resolved before current race behavior is treated as a contract). Both
are prerequisites rather than side concerns.

## Open decisions

- Whether ask and reply bodies justify the lifetime redesign at all, given that the report
  direction — the motivating case — did not need it.
- Whether run-directory retirement should leave a tombstone so a late reader can tell
  "retired after consumption" from "settled without writing".
