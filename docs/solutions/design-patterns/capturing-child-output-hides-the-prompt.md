---
title: Capturing a child's output hides the prompt it is blocked on
date: 2026-09-06
category: design-patterns
module: agent-platform
problem_type: design_pattern
component: development_workflow
severity: high
root_cause: incomplete_setup
resolution_type: code_fix
related_components:
  - tooling
  - chezmoi
applies_when:
  - "A wrapper redirects a child process's stdout or stderr into a file, a variable, or /dev/null"
  - "A script shells out to a third-party CLI whose prompting behaviour it does not control"
  - "A non-interactive flag or environment variable is being treated as proof that a child cannot block on input"
  - "A chezmoi run script, a shell alias, or another unattended path invokes a command that may ask a question"
  - "Deciding what a denied prompt should now fail as, once the child can no longer wait for an answer"
symptoms:
  - "A command sits at 0% CPU behind a blank screen; the process is in state S+ with no children and no open sockets"
  - "The same command works under --verbose and hangs without it"
  - "A stall is indistinguishable from slow work because the path prints nothing before or during the call"
  - "chezmoi apply never returns, and the run script it is inside has no timeout of its own"
tags:
  - output-capture
  - child-stdin
  - subprocess-wrapper
  - interactive-prompt
  - silent-stall
  - timeout
  - chezmoi
  - bash-3-2
---

# Capturing a child's output hides the prompt it is blocked on

## Context

This repository hit the same defect twice in one week, in two unrelated components, and
closed both on 2026-09-04.

**The skills wrapper.** `update-all` (`home/dot_aliases:298`) stalled after `brew upgrade`
behind a blank screen. The blocked process was `skills update` from
`home/dot_local/bin/executable_skills`, sitting in `S+` with no children and no open
sockets. `run_npx` redirected the upstream Skills CLI into `$TMPDIR/skills-output.XXXXXX`
and printed that file **only when the exit status was non-zero** — and a running process
has no exit status, so on the non-verbose path nothing the child wrote could reach the
terminal until the child was finished. Not an oversight: a consequence of the design.
Meanwhile stdin was never redirected, so the child kept the caller's tty and could read
from it. The capture file held a rendered `@clack/prompts` question:

```
Warning: The following skills from smithersai/smithers appear to have been
deleted upstream:
  • smithers
◆  Would you like to remove the local copies of these deleted skills?
│  ● Yes / ○ No
```

**The unattended chezmoi launcher.** `make test-local` sat live for 8m45s and produced no
verdict. Its process tree ended at `modify_dot_claude.json` calling `op read`, waiting on
interactive 1Password authorization nobody was there to grant (closed issue
`2026-08-30-006`). The remedy landed in PR #165: `tests/helpers/chezmoi-unattended` now
passes `</dev/null` on every chezmoi invocation that has not already been handed a finite
stdin (`:215`, `:238`, `:267`). The `--finite-stdin` branch at `:264-265` opts out on
purpose, because its caller guarantees EOF — the same converse argued in rule 1 below.

Together with the two test-runner hangs already documented in
`outliving-processes-hang-the-suite.md`, that is four incidents across three contexts — a
test runner, a deployment dry-run, and a shipped wrapper — all stalled on a stdin that
never reaches EOF. The two above add the aggravating half the test-runner pair does not
have: the caller had also captured the output, so the question that was waiting could not
be seen.

Three separately reasonable decisions produced the skills case:

1. **Output was captured** so a successful run stays quiet. That removed the only channel
   the prompt could have used to announce itself.
2. **stdin was left alone**, because nothing was being fed to the child. That preserved
   the only channel the prompt could use to block on.
3. **Non-interactivity was inferred from flags.** `invoke_npx` runs the child under
   `env -i … LC_ALL=C CI=1 NO_COLOR=1` (`home/dot_local/bin/executable_skills:91-95`) and
   `run_add`/`run_remove` pass `--yes` (`:165`, `:168`). Per the originating record,
   upstream ignored `CI=1` for this confirmation, and `skills update --help` documented
   `-y, --yes` only as "Skip scope prompt" — already answered by `--global` — so no
   documented update flag covered the deletion question. `run_update` passed no
   confirmation flag at all.

Nothing bounded the wait. And the blast radius was not the interactive alias:
`home/.chezmoiscripts/run_onchange_after_9-sync-agent-skills.sh.tmpl:42` ends in
`exec "$wrapper" sync`, so the same prompt could block a `chezmoi apply` indefinitely, on
a path where no human is present to answer it.

## Guidance

**1. Redirecting a child's output and redirecting its input are one decision, not two.**
The moment you capture stdout or stderr, the child's ability to ask a question is gone
but its ability to wait for the answer is not. Close the gap on the same line:

```bash
invoke_npx "$@" </dev/null > "$output" 2>&1 &
```

`home/dot_local/bin/executable_skills:127-129` carries the reason as a comment, which is
where it belongs — the redirect reads as noise otherwise:

```bash
# Captured output cannot render a prompt, so deny the child a terminal to
# wait on. Upstream ignores CI=1 for its deleted-skill confirmation.
```

The converse holds too, and is worth stating so nobody over-applies the rule: where you
do **not** capture *and a human owns the terminal*, you do not need `</dev/null`. Under a
test runner the converse does not hold: the parent's stdin is a pipe nothing closes, so
the sibling document's rule 3 applies there whether or not you captured. The same script runs
`chezmoi git -- pull --ff-only` (`:187`) and `chezmoi git -- push` (`:297`) with their
output on the caller's terminal, and a credential prompt from either is visible and
answerable. Capture is what turns a prompt into a hang.

**2. A `--yes` flag or a `CI=1` variable is a request; a closed descriptor is an
enforcement.** A flag depends on the callee honouring it for the specific question it
happens to ask, and a CLI you do not own adds questions between releases —
`npx --yes skills@latest` (`:95`) is a floating dependency, so the prompt set can change
under you with no local diff. `</dev/null` does not depend on the callee's cooperation:
`read` gets EOF. Keep the flags, since they produce better behaviour when honoured, but
never count them as the guarantee. `executable_update-pins:40-46` already writes the
distinction down for git:

> `GIT_TERMINAL_PROMPT` only suppresses a credential prompt; it does nothing about a
> server that accepts the connection and then stalls.

**3. "Print the capture on failure" means "print nothing" for as long as the process is
alive.** A capture buffer is a record of the past; a hang is a fact about the present. If
the buffer's only consumer is keyed on exit status, then by construction it cannot help
during the one failure mode where it is most needed. Either stream something live, or
bound the wait so a status eventually exists. `run_npx` now does both.

**4. Denying input converts a hang into a failure — decide what that failure means.**
This is the half that is easy to skip, and the chezmoi case is the clearer teacher:
once `op read` can no longer wait, the apply does not silently produce a wrong diff. The
unattended contract renders credential-sensitive targets with non-secret canaries, or
omits them and names what was not checked. A `</dev/null` that turns a stall into a
plausible-looking wrong answer has moved the bug, not fixed it.

The wrapper's version of the same decision is a distinguishable status: on expiry
`run_npx` prints the captured output *and* an explanatory line, then returns 124
(`home/dot_local/bin/executable_skills:148-152`), so a caller can tell a termination from
an upstream failure. Two mechanics carry over from the neighbouring learnings rather than
being re-derived here — the bound must terminate the **process tree**, because `npx`
spawns `node` and TERMing only the direct child orphans the grandchild
(`terminate_tree`, `:99-115`); and the bound is a hang guard, so 600s (`:16`) sits far
above any legitimate run.

**5. Split the contract by who is watching, not by a second verbosity flag.** The same
wrapper runs under a human and under `chezmoi apply`, and those want opposite things.
`--verbose` bypasses capture entirely (`:120-123`) — no temp file, no background job, no
deadline, stdin still attached — so a human can read the question and answer it. A
wrapper with no such path pushes users into reconstructing the raw invocation by hand,
which is how the enforced behaviour gets bypassed in ways nobody reviews. Progress output
takes the same split from the descriptor rather than a flag:

```bash
if [ "$SKILLS_HEARTBEAT" -gt 0 ] && [ -t 2 ] && [ "$waited" -ge "$heartbeat_at" ]; then
  printf 'skills: still running (%ss)\n' "$waited" >&2
  heartbeat_at=$((heartbeat_at + SKILLS_HEARTBEAT))
fi
```

(`:140-143`, with the matching start line at `:170`.) The heartbeat is what makes a slow
run distinguishable from a dead one — the diagnostic gap that made the original incident
cost what it did. Two honest limits on the current implementation: `run_add` prints its
`Installing skills from …` line to stdout unconditionally in non-verbose mode (`:164`)
while `run_update` prints to stderr only on a terminal (`:170`), so the silence contract
really describes upstream's output rather than the wrapper's; and because the gate is a
real terminal, a Herdr pane or a CI log still sees nothing between the start line and the
result.

## Why This Matters

This class produces no error text, no stack, no failing assertion, and no log line. The
evidence is the process table. The 2026-09-04 diagnosis needed `ps` state (`S+`), a child
count, an open-socket check, and then reading a temp file by hand to discover that the
"stalled network call" was a question. Nothing in the terminal pointed at any of it.

Reachability from automation is what raises the severity. `update-all` stalling costs a
person their attention; the same wrapper reached from
`run_onchange_after_9-sync-agent-skills.sh.tmpl:42` stalls `chezmoi apply`, which is this
repository's entire delivery mechanism — one hang there blocks every unrelated
managed-file change on the machine, and the person running apply has no reason to suspect
the skills step. `make test-local` failed the same way from the other direction.

The generalisable cost is that the two decisions sit far apart in a reviewer's head.
"Capture the output so success is quiet" is a UX decision. "Leave stdin alone" is a
non-decision — you leave it alone by writing nothing at all. Reviews catch decisions; they
do not catch the absence of one. That is why this belongs in a document rather than in
the diff.

## When to Apply

- Writing or reviewing any redirection of a child's stdout or stderr — to a temp file,
  into `$( )`, or to `/dev/null`. Ask in the same breath what that child's stdin is.
- Wrapping a third-party CLI, especially one resolved at run time (`npx …@latest`,
  `op`, `gh extension`) whose prompt set can change without a local diff.
- Adding anything to `home/.chezmoiscripts/` that shells out. No human is guaranteed to be
  watching an apply, and there is no ambient timeout around a run script.
- Reviewing a fix that adds `</dev/null`: check what the denied prompt now fails as, and
  whether that failure is honest rather than merely quiet.
- Triaging a process at 0% CPU with no output. Read the wrapper's capture file before the
  terminal — the terminal is blank by design.

## Examples

**Before** — `run_npx` as it stood before `f382d86`. Every line is defensible; together
they can neither report a prompt nor stop waiting for one:

```bash
output="$(mktemp "$TMPDIR/skills-output.XXXXXX")" || return 1
trap 'status=$?; rm -f "$output"; trap - EXIT HUP INT TERM; exit "$status"' EXIT HUP INT TERM
invoke_npx "$@" > "$output" 2>&1
status=$?
[ "$status" -eq 0 ] || cat "$output" >&2
```

**After** — `home/dot_local/bin/executable_skills:125-156`, abridged:

```bash
output="$(mktemp "$TMPDIR/skills-output.XXXXXX")" || return 1
trap 'status=$?; [ -z "$NPX_PID" ] || signal_tree TERM "$NPX_PID"; rm -f "$output"; trap - EXIT HUP INT TERM; exit "$status"' EXIT HUP INT TERM
invoke_npx "$@" </dev/null > "$output" 2>&1 &
NPX_PID=$!
started=$SECONDS
while kill -0 "$NPX_PID" 2>/dev/null; do
  sleep "$SKILLS_POLL_INTERVAL"
  waited=$((SECONDS - started))
  if [ "$SKILLS_TIMEOUT" -gt 0 ] && [ "$waited" -ge "$SKILLS_TIMEOUT" ]; then
    timed_out=1; terminate_tree "$NPX_PID"; break
  fi
  ...
done
wait "$NPX_PID"; status=$?
if [ "$timed_out" -eq 1 ]; then
  cat "$output" >&2
  printf 'skills: upstream produced no result within %ss and was terminated\n' "$SKILLS_TIMEOUT" >&2
  status=124
fi
```

The trap also gained `signal_tree TERM "$NPX_PID"`: once the child is backgrounded, a
Ctrl-C on the wrapper no longer reaches it, so the wrapper has to forward the signal.

**Where the tree already has the shape, and where it does not.** This inventory is the
reason the rule is worth carrying rather than re-deriving — these are the sites where the
next upstream release that adds a confirmation reproduces the incident.

All three mechanisms — capture, `</dev/null`, and a bound:

- `home/dot_local/bin/executable_herdr-pane-labels:432-443`
  (`run_budgeted_command_within`) — `"$@" </dev/null >"$outfile" 2>"$errfile" &` with a
  `sleep`-based watchdog, killed and reaped unconditionally after the `wait`. Simpler than
  `run_npx` and correct for its callees, which are single `git` processes with no
  grandchildren.
- `home/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh:424-447`
  (`hpl_cutover_capture_with_deadline`) — same `</dev/null`, same `status=124`
  convention. It runs inside a chezmoi run script, which is what makes it
  non-negotiable there.
- `home/dot_local/bin/executable_skills:117-157`.

Stdin denial without a bound:

- `tests/helpers/chezmoi-unattended` at lines 215, 238 and 267 — the launcher from PR #165.
  Only `:215` captures; the other two are pass-through. Nothing in the launcher or in its
  `Makefile` caller imposes a deadline, so a chezmoi child that blocks on something other
  than stdin still waits indefinitely. The stdin half of the rule is applied; the bound is
  not.

Capture without the stdin redirect, still:

- `tests/bashunit/test-dsl.bash` at lines 118 and 124 — the `run` helper's
  `( "$@" ) > "$_bats_run_out" 2>&1`, stdin inherited. The highest-traffic instance of this
  shape in the tree, and the site behind incident 2 of the neighbouring learning: under the
  runner the inherited stdin is a pipe whose write end nothing closes.
- `home/dot_local/bin/executable_herdr-pane-labels:1112` —
  `herdr agent rename … >"$output_file" 2>&1`, read only on failure, stdin inherited, no
  bound. The same shape as the bug.
- `home/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl:64` —
  `herdr plugin install "$repo" -y >/dev/null 2>&1`. Worse in one respect (output is
  discarded, so there is nothing to inspect afterwards) and it repeats the exact reasoning
  that failed here: a `-y` flag standing in for a guarantee, inside a chezmoi run script.
- `home/dot_local/bin/executable_update-pins:347` — `mise outdated --bump -J 2>/dev/null`
  inside a command substitution: stdout captured, stderr discarded, stdin inherited,
  network-touching, unbounded.
- The `$(herdr …)` reads through `home/dot_local/lib/herdr-child-*.sh`. Safe today only
  because the `herdr` CLI does not prompt — a property of the callee, not of the call
  site, and written down nowhere.

None of these are claimed as defects.

**Contrast — the tool-native variant.** `executable_update-pins:35-61` reaches the same
end by different means: `GIT_TERMINAL_PROMPT=0` plus
`GIT_HTTP_LOW_SPEED_LIMIT`/`_TIME` for `git ls-remote`, and `curl --max-time 20` for its
HTTP siblings. That is the right call when the callee ships both knobs and its comment at
`:40-43` explains why it avoids a `timeout` binary macOS does not have. It works because
those callees are stable, well-documented tools — precisely what an `npx …@latest`
dependency is not.

**Testing it.** `tests/bashunit/scripts_test.sh:8724` (no-hang) and `:8775` (bounded wait)
both failed against the previous wrapper with 21s and 41s stalls. Two things about them
generalise. The hostile stdin has to be *reproduced*: test 2723 hands the wrapper the read
end of a pipe the parent never writes to and never closes, because "an open descriptor
that never reaches EOF" is the attribute a tty has and a harness's stdin does not — under
a pipe that closes, the pre-fix wrapper passes. And the assertion targets the grandchild:
test 2724's stub records a `sleep 300 &` PID and polls until it disappears, because a
`kill "$NPX_PID"`-only implementation satisfies every other assertion in that test.

## Related

- `docs/solutions/design-patterns/outliving-processes-hang-the-suite.md` — the nearest
  neighbour and the doc this one defers to. That one is about *your* process outliving its
  parent: descriptors a departing child keeps open, detached workers, teardown races, wait
  loops needing abandonment exits, and reproducing an inherited attribute in a fixture
  (its rule 9, the technique behind tests 2723 and 2724). Its rule 3 states the same
  `</dev/null` for commands in tests. This document is the mirror image and does not
  restate any of it: a foreground child in shipped code that you are actively waiting for,
  blocked because the caller took away its voice while leaving it its ears. The redirect
  looks identical; the review trigger and the required companions — a designed failure
  meaning and a terminal-gated liveness signal — are different.
- `docs/solutions/architecture-patterns/child-initiated-callback-over-in-turn-supervision.md`
  — the same problem where you *own* the prompt surface. There the answer is to suppress
  or pre-grant the prompt; here it was not suppressible, so the answer is to remove the
  input channel. Both keep the split that an attended path stays interactive.
- `docs/solutions/design-patterns/external-review-legs-as-unreliable-subprocesses.md` —
  its rule 2 pins execution-mode environment variables as the hard layer under a prose
  instruction. This incident is a measured case where that layer was soft: `CI=1` was set
  and declined, and the only way to observe the decline was the hang.
- `docs/solutions/design-patterns/idle-machine-wall-clock-bounds-are-latent-flakes.md` —
  why `SKILLS_TIMEOUT` is 600s rather than 30s, and why the timeout path returns a
  distinct 124 with the captured output instead of a generic non-zero.
- `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md` — the
  oracle standard tests 2723 and 2724 meet.
- Source anchors in the current tree: `home/dot_local/bin/executable_skills`,
  `tests/helpers/chezmoi-unattended`,
  `home/dot_local/bin/executable_herdr-pane-labels`,
  `home/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh`,
  `home/dot_local/bin/executable_update-pins`,
  `home/.chezmoiscripts/run_onchange_after_9-sync-agent-skills.sh.tmpl`,
  `home/.chezmoiscripts/run_onchange_after_7-install-herdr-github-plugins.sh.tmpl`,
  `home/dot_aliases`, `tests/bashunit/scripts_test.sh`.
- Originating closed issues: `2026-09-04-004` (the skills wrapper; carries the verbatim
  prompt transcript and the process evidence) is still a live file under `docs/issues/`.
  `2026-08-30-006` (the 1Password stall, resolved by PR #165) was pruned in a backlog
  sweep and survives only in git history. The wrapper fix landed as
  `f382d86` — committed directly, no PR — and was later reworked by #171, which decoupled
  the poll interval from the deadline so a test can sample faster without moving the
  bound it asserts.
