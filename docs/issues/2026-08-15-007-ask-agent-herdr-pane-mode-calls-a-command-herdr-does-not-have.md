---
title: "ask-agent's herdr-pane mode calls `herdr wait output`, a command herdr does not have, so every consult inside herdr fails"
short_description: "ask-agent's herdr-pane mode calls `herdr wait output`, a command herdr does not have, so every consult inside herdr fails"
type: "bug"
category: "herdr"
tags: ["herdr","bug"]
date: "2026-08-15"
status: "done"
priority: "low"
closed: "2026-08-15"
---

# ask-agent's herdr pane mode is dead: `herdr wait output` is not a herdr command

## Why this exists

`home/private_dot_claude/skills/ask-agent/scripts/ask.sh:71` waits for the consult with:

```bash
herdr wait output "$PANE" --match "$MARK" --timeout 1800000 >/dev/null || WAIT_RC=$?
```

herdr has no top-level `wait` verb. The installed CLI answers:

```
unknown command: wait
run 'herdr --help' for usage
```

The wait subcommand lives under `pane`, and its name has a hyphen: `herdr pane wait-output` (`herdr pane --help` → `wait-output  Wait for matching pane output`).

All three copies of the file carry the same line — this repo checkout, `~/.local/share/chezmoi/home/...`, and the live `~/.claude/skills/...` — so it is a real defect, not chezmoi drift.

**A second failure follows from the first.** `herdr wait output` returns non-zero immediately, the parent `ask.sh` finishes, and its EXIT trap deletes the question file `$QF` while the spawned pane is still starting. The pane's agent script then reads nothing:

```
cat: /var/folders/.../tmp.CUuUngS55w: No such file or directory
```

So the consult runs with an empty question, and the caller gets the misleading `WARNING: timed out waiting for the consult (30 min)` after ~0 seconds.

Reproduced 2026-08-15 inside herdr (`HERDR_ENV=1`, pane `w4:p3Y`):

```bash
bash ~/.claude/skills/ask-agent/scripts/ask.sh opencode "<question>" --cwd /Users/andrew.b/Projects/my-mac-setup
```

The `--headless` path is unaffected and returns a correct answer, which is why the defect stayed invisible: the 15 recorded ask-agent consults (2026-07-09 … 2026-08-14, all in the platform repos) either ran outside herdr or passed `--headless`.

## Scope

- Fix the wait call in `home/private_dot_claude/skills/ask-agent/scripts/ask.sh:71` to the real command and verify its flags (`--match`, `--timeout`) against `herdr pane wait-output --help`.
- Keep the question file alive until the pane has consumed it, or pass the question by a route the trap cannot revoke. A correct wait call alone still leaves a race between the parent trap and pane startup.
- Distinguish a genuine 30-minute timeout from an immediate wait failure in the warning text; the current message reports a timeout that never happened.
- Add a test that catches a dead herdr verb in the skills. Commit `a574649` ("Repair three dead commands in the skills, and give shared references one home", 2026-08-15) audited exactly this class of defect by hand and missed this call site.

## Open decisions

- Whether `ask.sh` should fall back to the headless path when the herdr wait fails, or fail loudly. A silent fallback hides a broken pane mode; a hard failure blocks a consult that could still have run.

## Resolution

Fixed in `home/private_dot_claude/skills/ask-agent/scripts/ask.sh`. Fixing the verb alone was not enough — the live run turned up two further defects in `herdr pane wait-output` on herdr 0.8.0, both now pinned by tests:

1. **The pane id must come first**, before the options, though `--help` prints `Usage: herdr pane wait-output [OPTIONS] … <PANE_ID>`. Every option-first spelling is rejected with `unknown option: …`.
2. **A wait timeout exits 0** and reports `{"error":{"code":"timeout"…}}` on stdout. Branching on `$?` would have read a timed-out consult as a finished one. The script now classifies on the payload: `"type":"output_matched"` → matched, `"code":"timeout"` → timeout (exit 124), anything else → the wait call itself broke (exit 1, with herdr's own first line quoted). `herdr agent wait`, which `herdr-pair` uses, exits 1 on timeout and is unaffected.

Also changed:

- The EXIT trap no longer deletes the question file while a pane may still be reading it (`PANE_OWNS`). That deletion is what emptied the consult; the pane's agent script died on `cat: … No such file or directory`.
- `ask.sh` probes `herdr pane wait-output --help` before splitting a pane. A herdr without the command runs headless with a warning instead of spending a pane and an agent run on a wait that cannot work. This settles the open decision for the *missing verb* case; a wait that fails *after* the consult started still fails loudly, because the work is already in flight.
- The wait reads `--source recent-unwrapped`, so a wrapped snapshot cannot split the completion marker across two lines.

Tests in `tests/scripts.bats`: four new cases around the pane path (answer delivered with the pane id first; question file kept alive when the wait fails; timeout-with-exit-0 reported as a timeout; headless fallback when the verb is absent), plus a guard that checks every `herdr <group> <command>` in the skills' `*.sh` against the installed binary, falling back to a group allowlist where no herdr is installed (CI). The guard is red on both `herdr wait output` and `herdr pane bogus-verb`.

Verified live inside herdr on 2026-08-15: an opencode consult ran in pane `w4:p42`, its answer came back on stdout, and `ask.sh` exited 0. Two documented traps were added to the `herdr` skill's "Learn the current CLI" section.

The fix reaches the live `~/.claude/skills/ask-agent/scripts/ask.sh` only after `chezmoi apply`; until then only the repo copy carries it.
