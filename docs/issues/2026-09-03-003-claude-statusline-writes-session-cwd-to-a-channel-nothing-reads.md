---
title: "Claude statusline writes session cwd to a channel nothing reads"
short_description: "executable_statusline.sh writes $HOME/.cache/herdr-task-sync/agent-cwd/<session-id> on every render, but neither the repo (herdr-pane-labels derives cwd from pane JSON) nor the installed herdr binary (strings shows zero agent-cwd occurrences) reads it, so worktree-aware cwd reporting is silently lost and cache files accumulate unbounded."
type: "bug"
category: "herdr"
tags: ["hooks","pane-labels","dead-code"]
date: "2026-09-03"
status: "open"
priority: "medium"
---

## Why this exists

`home/private_dot_claude/hooks/executable_statusline.sh` (`herdr_record_session_cwd`, lines 10–24) writes the session's real working directory to `${HERDR_TASK_SYNC_STATE_DIR:-$HOME/.cache/herdr-task-sync}/agent-cwd/<session-id>` on every statusline render. The comment in the hook still describes this as the live contract with herdr-task-sync, but the reader was stranded by the herdr-task-sync → herdr-pane-labels cutover:

- `home/dot_local/bin/executable_herdr-pane-labels` derives cwd from herdr's pane JSON (`foreground_cwd`, then `cwd`) and contains zero occurrences of `herdr-task-sync` or `agent-cwd`.
- The installed herdr binary (`/opt/homebrew/bin/herdr`) contains zero `agent-cwd` strings.
- The only other repo reference is a legacy-name stub in `tests/helpers/herdr_pane_labels.bash:1002` for the cutover test.

Impact: the capability the channel existed for — labeling a pane by the session's *worktree* cwd rather than the pane process cwd, which never moves — is silently lost, and `~/.cache/herdr-task-sync/agent-cwd/` accumulates one file per session forever. Open issues 2026-08-27-004 and 2026-08-27-005 ask OpenCode and Pi to report cwd "like Claude does", i.e. into this same dead channel.

## Scope

Decide the channel's fate and make the code match:

- If worktree-aware cwd labeling is still wanted: restore a reader (herdr-pane-labels consults `agent-cwd` before pane JSON) and add sweep/expiry for stale session files.
- If not: delete `herdr_record_session_cwd` and its comment from the statusline hook, update the legacy stub in `tests/helpers/herdr_pane_labels.bash`, and re-scope issues 2026-08-27-004/-005, which currently target the dead channel.

## Open decisions

- Restore the reader or delete the writer — depends on whether pane labels for worktree sessions are observed to be wrong in practice.
