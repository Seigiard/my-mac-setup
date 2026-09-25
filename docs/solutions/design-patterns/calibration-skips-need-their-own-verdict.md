---
title: A calibration that can skip needs its own verdict
date: 2026-09-25
category: design-patterns
module: testing
problem_type: design_pattern
component: testing_framework
severity: high
resolution_type: workflow_improvement
related_components:
  - ci
  - herdr
  - tooling
applies_when:
  - "A conformance check compares a test double against the real program it imitates"
  - "That check guards itself with `command_exists X || skip` or a non-zero-exit skip"
  - "Deciding whether a calibration's precondition belongs in the same test as the assertions it gates"
  - "A calibration's oracle exists on the workstation but not in CI, or the other way round"
  - "Choosing between skipping a calibration and pinning a recorded capture of the real output"
symptoms:
  - "A fake's only calibration reports `skipped` on every machine, so every test running against that fake is adjudicated by an unverified stub"
  - "The real binary answered and disagreed, but a blanket non-zero-exit guard turned the disagreement into a skip"
  - "One precondition at the end of a calibration discards the assertions that already passed, and the run reports a single `skipped`"
  - "A calibration needs the host registry, account, or session to happen to contain the case it compares"
  - "The suite is green in CI and red on the one machine where the oracle exists"
tags:
  - test-fakes
  - conformance-check
  - oracle
  - skip-guards
  - false-green
  - semantic-tests
  - bashunit
---

# A calibration that can skip needs its own verdict

## Context

`fakes-need-the-real-binary-as-oracle.md` establishes that a fake of another
program can only be adjudicated by that program, and that where the program is
absent the check must skip rather than fall back to a locally invented expected
shape. That is correct and incomplete. A skip is exit 0. The runner folds it into
a green run, and the tests that run against the fake keep passing on a claim
nothing checked.

The 2026-09-25 test-corpus audit found three shapes of this in one suite:

- `tests/bashunit/scripts_test.sh` test 3074, the only calibration of the Skills
  CLI stub, turned **any** non-zero exit of the real CLI into `skip`. A CLI that
  had changed its lock-file layout — the regression the test exists to catch —
  read as an absent oracle.
- Test 08523 compared the herdr plugin-list fakes against the installed binary,
  then ended with a precondition requiring the **host registry** to happen to
  hold both a `local` and a `github` registration. On a developer machine holding
  only `github` plugins the whole test reported `skipped`, discarding three
  assertions that had already passed and leaving every `"kind":"local"` fake in
  the file unadjudicated.
- The codex app-server fake in test 27210 claimed a JSON-RPC reply shape that its
  nominal oracle, test 27209, never looked at: 27209 asserted the **cache our own
  script writes**, not codex's reply. The fake's claim had no oracle at any
  setting of the opt-in flag that gates it.

`herdr_resource_tree_test.sh` test 004 carried the first shape as well, and
demonstrates the sting in the tail: on the one machine where the oracle exists it
goes red on a herdr patch-version bump, and in CI — where herdr is absent — it
skips. The verdict a calibration produces is the *only* thing standing between a
fake and unchecked drift, so what that verdict does when the oracle is missing is
part of the design, not an afterthought.

## Guidance

### 1. Skip on a precondition, never on a status

`|| skip` on the oracle's exit status cannot tell "there is no oracle here" from
"the oracle answered and disagreed", and the second is the entire point of the
check. Name the unreachable cases, give each one a distinct status, and let every
other non-zero status be red:

```bash
  # 124 is the wrapper's timeout and 78 its no-running-server verdict. Both are
  # named environment preconditions; every other non-zero status is real Herdr
  # refusing the call, which this calibration must report as red.
  if [[ "$status" -eq 124 || "$status" -eq 78 ]]; then
    skip "no running Herdr server can answer api snapshot: $output"
  fi
  assert_success
```

The unreachable markers come from the program, not from a guess: herdr's
`error.code == "server_not_running"`, the Skills CLI's registry and network
strings. `assert_success` immediately after the guard is what makes the guard a
filter rather than a swallow.

### 2. Construct the case instead of hoping the environment holds it

A calibration that needs the host registry, account, or session to contain the
compared case is a calibration that will skip. Where the real program can be
asked to *create* the case in an isolated home, do that, and the skip disappears
entirely:

```bash
  run env -i HOME="$work/home" PATH="$PATH" XDG_CONFIG_HOME="$work/home/.config" \
    HERDR_SOCKET_PATH="/tmp/mms-herdr-plugin-contract-$$.sock" \
    herdr plugin link "$work/plug" --enabled
  assert_success
```

The real binary registers a throwaway plugin and reports back what it recorded.
Nothing on the expected side comes from the patch, and no machine has to happen
to be configured a particular way. This converted test 08523 from "skipped
everywhere" to "runs wherever herdr is installed".

### 3. One precondition, one verdict

A precondition placed after assertions throws their result away: bashunit and
bats both report the test as `skipped` whatever ran before the `skip`. When a
calibration has two halves with different preconditions, split it into two tests,
so the half that can be verified is reported as verified:

- 08523 owns the `local` half, constructed, and skips only where herdr is absent.
- 08530 owns the `github` half, which cannot be constructed offline — `plugin
  install` resolves a ref over the network — and carries its own named skip.

The pass count is not the point; the point is that the run says which half was
adjudicated. Ordering assertions before an unavoidable trailing skip is a partial
mitigation, not a substitute: the verdict still reads `skipped`.

### 4. Where the oracle must stay opt-in, record the capture

Some oracles cost more than a test run should: a live account, a paid API, a
network round trip on every developer's suite. Those stay behind an explicit
flag. The fake they guard is then unverified by default, and the honest response
is to give its claim stated provenance rather than leaving it anonymous — the
emulated version, the exact command that read it, and the date:

```sh
# Captured from the installed binary on 2026-09-25, codex-cli 0.157.0, by
# speaking the same newline-delimited JSON-RPC the refresh path speaks:
#   codex app-server  # then initialize, initialized,
#                     # account/rateLimits/read {"excludeResetCreditDetails":true}
```

A recorded capture does not adjudicate anything. What it does is turn "the fake
is wrong" from a discovery into a comparison, and make the gap auditable: a
reader can see what was checked, when, against what. Pair it with a real
comparison inside the opt-in test, so enabling the flag actually calibrates the
fake instead of only exercising the live path.

### 5. Declare the emulated payload once

A fake's claim can only be calibrated if there is one claim. Where several tests
answer with the same payload, extract it into one helper the calibration reads,
so the comparison covers every caller:

```bash
codex_app_server_reply() {
  local used_percent="$1" window_minutes="$2" resets_at="$3" credits="$4"
  printf '{"jsonrpc":"2.0","id":2,"result":{...}}' ...
}
```

Deliberate variation is not duplication — a malformed fixture, a disabled-registry
fixture and an enabled one are three different claims and stay three literals.
Extract only what is genuinely the same payload.

### 6. Report the skip by name, and compare skip identities

`docs/agent-verification.md` names the live oracles whose skips must be reported
by name. Add each new one to that list. A skip count is not a skip set; see
`skip-set-parity-proves-reduced-dependencies.md` for why the identity, not the
number, is the thing to diff across environments.

## Why This Matters

The cost is not one missing test. A calibration is a *fan-in* point: every
assertion written against the fake inherits its verdict. When the calibration
skips, a single silent exit 0 withdraws adjudication from the whole family at
once — three tests in the Skills CLI case, two in the codex case, every
`"kind":"local"` fixture in the herdr case — and the run reports all of them
passing.

That is worse than the plain false green the fakes doc addresses, because the
evidence looks like it exists. Someone reading the suite finds a test named
"fake fields match the installed Herdr contract" and reasonably concludes the
fields were checked.

The remedy is cheap and one-time. Narrowing a status guard to a named
precondition costs a few lines. Constructing the compared case usually costs less
than the skip guard it replaces. Splitting one calibration into two costs a test
id. None of these grows with the fake.

## When to Apply

Apply whenever a test compares a double against the real software it imitates,
and that comparison can decline to run: a stub CLI, a replayed protocol, a
recorded JSON fixture, a fake HTTP service. The trigger is the presence of a skip
path in a conformance check, not the size of the fake.

Do not apply it to an ordinary environment guard on a behavioral test.
`is_macos || skip` on a macOS-only behavior removes coverage that genuinely does
not exist elsewhere, and nothing downstream is adjudicated by a fake. The
distinction is fan-in: does anything else in the suite rest on what this test
declines to check?

Do not reach for a locally invented expected value to avoid a skip. That is the
tautology the calibration replaces, and it is worse than the skip.

## Examples

**The false green, demonstrated.** With `herdr_resource_tree_test.sh` test 004 as
it stood, a stub herdr that answered `api snapshot` with
`{"error":{"code":"unsupported_request","message":"api snapshot was removed"}}`
— upstream dropping the call the whole fixture reproduces — produced:

```
↷ Skipped: agent fixture matches the installed Herdr boundary
    real Herdr returned no snapshot: {"id":"cli:api:snapshot","error":{"code":"unsupported_request",...
```

After narrowing the guard to `server_not_running` and `124`, the same injection
produces a failure, while pointing `HERDR_SOCKET_PATH` at a socket no server
answers still skips with the named reason.

**The constructed oracle.** `scripts_test.sh` test 08523 reported
`↷ Skipped ... real registry does not currently expose both local and github
source kinds: github` on a host with herdr 0.9.1 installed and running. Linking a
throwaway plugin in an isolated config home turned it into 7 passing assertions
on the same host. Reversing the expected kind makes it red:

```
expected : {"enabled": "bool", "plugin_id": "str", "source.kind": "github"}
actual   : {"enabled": "bool", "plugin_id": "str", "source.kind": "local"}
```

**The oracle that looked at the wrong thing.** Test 27209 now reads the real
`account/rateLimits/read` reply and compares it to the reply
`codex_app_server_reply` produces, at the five fields `codex_refresh` reads.
Retyping `usedPercent` to a string in that helper turns it red with the two
dictionaries side by side; before the leg existed, the same retype left 27210 and
27213 green.

## Related

- `fakes-need-the-real-binary-as-oracle.md` — the doc this extends. It settles
  *what* may adjudicate a fake and says the check must be able to skip; this one
  covers what that skip then does to the run, and how to need it less often.
- `skip-set-parity-proves-reduced-dependencies.md` — why a green suite does not
  prove unchanged coverage, and why skip identity is the thing to diff.
- `semantic-regression-tests-over-source-shape.md` — the general standard: a test
  must change verdict with the protected behavior, and each contract needs one
  owner.
- `completion-is-not-a-verdict.md` — the same family one layer up: execution
  completing is not an acceptance verdict.
- `docs/agent-verification.md` — owns the list of live oracles whose skips must
  be reported by name.
