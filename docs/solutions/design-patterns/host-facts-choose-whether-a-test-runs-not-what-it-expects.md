---
title: Host facts choose whether a test runs, not what it expects
date: 2026-09-25
category: design-patterns
module: testing
problem_type: design_pattern
component: testing_framework
severity: high
resolution_type: test_fix
related_components:
  - chezmoi
  - ci
applies_when:
  - "A test's expectation differs by operating system, installed binary, or filesystem layout"
  - "A test guards an assertion with `if`, `case`, or `||` on an environment fact"
  - "Asserting that a background or fire-and-forget code path did nothing"
  - "A wait loop stands between a trigger and the assertion that reads its effect"
  - "Deciding whether a platform-specific contract deserves its own test or a branch inside one"
symptoms:
  - "Deleting the production guard under test leaves the whole suite green"
  - "An assertion reads an effect before the code path that produces it could have reached it"
  - "A suite reports a platform contract as covered on a machine that never evaluated it"
  - "One `if is_macos` / `else` pair passes on both hosts whatever the shipped rules say"
  - "A wait expires and the test continues to an assertion that its own timeout already satisfied"
tags:
  - host-dependent
  - conditional-assertions
  - visible-skip
  - false-green
  - background-work
  - causal-signal
  - bashunit
  - bun-test
---

# Host facts choose whether a test runs, not what it expects

## Context

This repository's suites run in three places with different facts on the ground: a macOS
workstation with the full toolchain, an Ubuntu container with a reduced Brewfile, and GitHub
Actions. Which binaries exist, which machine role `chezmoi init` binds, and how fast the machine is
all differ. Tests that read those facts have two ways to go wrong, and only one of them is loud.

The loud way is a flake. The quiet way is a test that keeps a second expectation for the other
machine, so it passes wherever it runs and proves the contract on neither.

The audit in #326 found both halves of this. `docs/solutions/design-patterns/idle-machine-wall-clock-bounds-are-latent-flakes.md`
owns the timing half — one bound serving as both hang guard and behavioral assertion. This document
owns the rest: environment branching, and the narrower timing case where a wait sits between the
trigger and the assertion.

## Guidance

### 1. A host fact decides whether the test runs; it never decides what the test expects

An `if`/`else` that picks between two expectations has two assertion paths, and no run ever takes
both. The macOS leg is never evaluated on Linux and the Linux leg is never evaluated on macOS, so a
regression on either side survives every run of the suite. This is the shape to remove:

```bash
  if is_macos; then
    assert_file_contains "$dest/.config/1Password/ssh/agent.toml" '^managed agent config$'
  else
    assert_file_contains "$dest/.config/1Password/ssh/agent.toml" '^existing agent config$'
  fi
```

Split it into one test per fact, each opening with a skip that names its precondition. The skip is
visible in the run summary, so a machine that could not reach a contract says so instead of counting
it as covered:

```bash
function test_templates_0381_a_valid_role_deploys_the_1password_agent_config() {
  is_macos || skip "only darwin binds a role (mbp2026) that uses the local 1Password SSH agent"
  ...
  assert_file_contains "$SSH_POLICY_DEST/.config/1Password/ssh/agent.toml" '^managed agent config$'
}
```

`tests/bashunit/platform_test.sh:122-176` is the worked shape: three tests, three named skips, one
exact assertion each, and a positive control in every one so a degenerate managed listing cannot
satisfy an exactly-empty expectation.

**Name the fact, not the platform.** The role split above skips on `is_macos`, but its message names
the role, because the ignore rule keys on `server` and not on the operating system; darwin is only
the host that can bind the other role. A message that says "macOS only" sends the next reader to the
wrong rule.

**An inventory that grows by platform is not this pattern.** `_smoke_critical_paths` in
`tests/bashunit/smoke_test.sh:151-161` appends darwin-only paths to a list, then asserts once that
every path in the list is deployed. There is no second expectation: on Linux those paths are not
claimed at all, and `platform_test.sh` 001-003 own the cross-check that the darwin-only set is
exactly the one `.chezmoiignore` names.

### 2. When the precondition must hold, fail instead of skipping

A skip is right where the fact is genuinely optional. Where the gate is supposed to guarantee the
fact, a skip deletes the check from the only run that was meant to make it.
`tests/bashunit/scripts_test.sh:7586-7597` splits the two: `bun` missing on a workstation is a skip,
`bun` missing inside a disposable-home gate is a `fail`, because it is a declared Brewfile dependency
there.

Separate "the oracle could not be reached" from "the oracle disagreed" by status, never by text
alone. `tests/bashunit/scripts_test.sh:9838-9857` reserves 124 for its own timeout and 125 for an
unreachable upstream, skips on those two, and lets every other non-zero status be the regression.

### 3. An assertion that a code path did nothing needs a signal that path cannot avoid

The worst false green in this class does not look conditional at all. It reads an effect at a moment
when the effect could not have arrived yet:

```ts
  startup({ reason: "reload" }, ctx);
  expect(calls).toEqual([]);            // green with or without the reason filter
```

`session_start` dispatches its work in the background, and the first `exec` is several awaits past
`mkdir`. At the synchronous `expect`, `calls` is empty whether the handler filtered the reason or
started a full update. Deleting `if (event.reason !== "startup") return;` from the extension left all
29 tests in `tests/pi-brew-auto-update.test.ts` green.

Widening the window does not fix it — that only trades the false green for a wall-clock guess. Find
something the forbidden path must touch **before** its first await, and count it. The handler cannot
hand the session UI to the update sequence without reading `ctx.ui`, so a recording getter observes
entry in the same synchronous turn:

```ts
  let uiReads = 0;
  const ctx = { get ui() { uiReads += 1; return fakeUi().ui; } };

  startup({ reason: "reload" }, ctx);
  expect(uiReads).toBe(0);

  startup({ reason: "startup" }, ctx);
  expect(uiReads).toBe(1);
```

The second `expect` is not decoration. It is the live control: if the handler ever stops reading
`ctx.ui` before its first await, the probe goes dead, and without the control a dead probe reads as
proof that nothing ran.

**Do not reach for a second concurrent run as the signal.** The obvious repair here — fire the
rejected event, fire a real one, and wait for the real one to finish — is not one. The two runs
contend for the same lock, and under one interleaving the forbidden run wins it and the legitimate
one goes silently contended, which is green again.

### 4. Bound every wait, and make the expiry say what it was waiting for

A wait that expires must fail on its own terms. A bare `while` with no bound turns a regression into
a hang, and a bound whose expiry falls through to the next assertion turns it into whatever that
assertion happens to accept.

In bashunit, either assert the counter or assert the thing the wait was for
(`tests/bashunit/scripts_test.sh:5467-5476`):

```bash
  while kill -0 "$watcher_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1)); sleep 0.01
  done
  [ "$attempt" -lt 500 ] || fail 'watcher never exited after child identity replacement'
  assert_dir_not_exists "$run_dir"
```

Use `[ ... ]` and not `[[ ... ]]`: a bare `[[ ]]` mid-body is inert under macOS Bash 3.2, which is
why `make lint` runs `scripts/check_bats_assertions.py`
(`docs/solutions/test-failures/bats-mid-test-compound-conditionals-bypass-errexit.md`).

An exit alone is usually too weak to be the verdict. A watcher that crashed before reading state and
one that retired correctly both satisfy "no event was delivered"; only the removed run directory
tells them apart, which is why the bound and the directory assertion appear together above.

In Bun, the runner's own per-test timeout is a bound, but it reports a hang with no idea which
condition was never met. Name it:

```ts
async function waitFor(ready: () => boolean, what: string): Promise<void> {
  const deadline = Date.now() + 10_000;
  while (!ready()) {
    if (Date.now() > deadline) throw new Error(`timed out after 10s waiting until ${what}`);
    await Bun.sleep(1);
  }
}
```

The bound is a hang guard, not an assertion. Size it so that only a stuck fixture can reach it, and
put the behavioral claim in the assertion that follows.

## Why This Matters

A conditional expectation costs more than a missing test. Both leave the contract unproven, but the
branch also reports itself as coverage: the suite counts the test as passed on every machine, and
the next person to touch that rule reads a green run as evidence. The audit found the 1Password
agent rule in exactly that state — two exact assertions, neither of which any single run could
falsify.

The background-work case is worse still, because nothing in it looks conditional. `expect(calls).toEqual([])`
reads like a strict assertion. It is strict about the wrong instant. The production guard it was
written to protect could be deleted outright with no test going red, which is the defining property
of a false green: it looks like evidence and it stops the next investigation.

Both repairs are the same move. Find the fact the code cannot avoid touching — a read of `ctx.ui`, a
retired run directory, the managed-file listing `chezmoi` really produced — and assert that. Let the
host fact decide only whether the test gets to run at all.

## When to Apply

- A test contains `if is_macos`, `case "$(get_os)"`, `command_exists`, or any other read of the
  environment, and an assertion sits inside one of its branches.
- An assertion reads an effect produced by work that was started but not awaited.
- A `while` or `until` loop stands between a trigger and the assertion that reads its effect.
- A skip message names a platform where the shipped rule keys on something else.
- A gate is meant to guarantee a tool's presence, and the test skips when it is absent anyway.

## Open weight

Roughly thirty herdr-child tests pass `--supervision-timeout 5000` where the deadline is not the
subject, alongside siblings that use `60000` and `600000` with the note "keep it out of reach so a
loaded run cannot race reap". A spurious timeout there produces a false red, never a false green, so
the sweep left them alone; if one of them flakes under `--jobs`, raise that test's deadline rather
than widening a shared bound.
