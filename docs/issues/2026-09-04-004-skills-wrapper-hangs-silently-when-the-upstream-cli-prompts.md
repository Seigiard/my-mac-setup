---
title: "Skills wrapper hangs silently when the upstream CLI prompts"
short_description: "run_npx captures upstream output to a temp file while leaving stdin on the tty, so an interactive Skills CLI prompt blocks update-all and chezmoi apply forever with an empty screen and no timeout."
type: "bug"
category: "agent-platform"
tags: ["skills","dotfiles","hang","timeout"]
date: "2026-09-04"
status: "done"
priority: "high"
closed: "2026-09-04"
---

## Why this exists

`update-all` (`home/dot_aliases`) stalled after `brew upgrade` with a blank
screen. The blocked process was `skills update` from
`home/dot_local/bin/executable_skills`, sitting in state `S+` with no children
and no open sockets.

`run_npx` redirects the upstream process to `$TMPDIR/skills-output.XXXXXX` and
prints that file only when the exit status is non-zero. While the process is
alive there is no exit status, so nothing reaches the terminal by construction.
stdin is never redirected, so the child keeps the tty and can wait for input.

The captured file held a rendered `@clack/prompts` question:

```
Warning: The following skills from smithersai/smithers appear to have been
deleted upstream:
  • smithers
◆  Would you like to remove the local copies of these deleted skills?
│  ● Yes / ○ No
```

`invoke_npx` sets `LC_ALL=C CI=1 NO_COLOR=1`, and `run_add` and `run_remove`
also pass `--yes`. The wrapper treats that as sufficient to guarantee a
non-interactive child, which is why capturing output was considered safe.
The Skills CLI ignored `CI=1` for this deletion prompt. `run_update` passes no
confirmation flag at all, and `skills update --help` documents `-y, --yes` only
as "Skip scope prompt", which `--global` already answers — so no documented
update flag covers the deletion question.

Nothing else limits the wait. There is no timeout, no heartbeat, and no
progress output on the `update` path, so a stall is indistinguishable from
normal work. `run_add` at least prints one line per source; `run_update` prints
nothing before the call.

The blast radius is not limited to the interactive alias.
`home/.chezmoiscripts/run_onchange_after_9-sync-agent-skills.sh.tmpl` invokes
the deployed wrapper during `chezmoi apply`, so the same prompt can block an
apply indefinitely.

## Scope

- Make the default (non-verbose) path non-interactive: give the upstream child
  `/dev/null` on stdin so a prompt cannot wait on input that will never arrive.
- Keep `--verbose` interactive, since a human is watching that path and needs to
  answer prompts.
- Add a bounded wait that terminates the upstream process tree and reports a
  non-zero status with the captured output, so no invocation can wait forever
  regardless of what upstream does.
- Emit progress on a terminal so a long run is distinguishable from a stall,
  without breaking the existing contract that a successful non-verbose run is
  silent for scripts and CI.
- Cover the no-hang and bounded-wait behavior in `tests/bashunit/scripts_test.sh`
  alongside the existing output-capture cases (272, 2721, 2722).

## Open decisions

None.

## Resolution

run_npx now gives the upstream child /dev/null on stdin so a prompt cannot wait on input that never arrives, supervises it with a bounded SKILLS_TIMEOUT (600s default) that terminates the whole process tree and returns 124 with the captured output, and prints an elapsed-seconds heartbeat plus an update start line only when stderr is a terminal, so a successful non-verbose run stays silent for scripts and chezmoi. --verbose keeps stdin attached so a human can still answer prompts. tests/bashunit/scripts_test.sh 2723 and 2724 cover the no-hang and bounded-wait behavior; both fail against the previous wrapper (21s and 41s stalls) and pass against the fix.
