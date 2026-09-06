---
title: A fake of another binary needs that binary as its oracle
date: 2026-09-06
category: design-patterns
module: testing
problem_type: design_pattern
component: testing_framework
severity: high
related_components:
  - herdr
  - tooling
applies_when:
  - "A test helper stubs, fakes, or replays another program's CLI or JSON contract"
  - "Assertions accumulate against a fixture that nothing ever compares to the thing it impersonates"
  - "Choosing how deep a conformance check should compare a fake against its original"
  - "A fake and the real thing are found to disagree below the level the check pins"
  - "The real binary is unavailable in some environments, so the check must be able to skip"
tags:
  - test-fakes
  - conformance-check
  - oracle
  - upstream-ownership
  - semantic-tests
  - herdr
  - bashunit
---

# A fake of another binary needs that binary as its oracle

## Context

`tests/helpers/herdr_pane_labels.bash` is a stub `herdr` executable. It reimplements the real
binary's `api snapshot` envelope, its `jq`-built snapshot skeleton, and its `--seq` / `--token`
high-water merge semantics, and every pane-label assertion in `tests/bashunit/scripts_test.sh`
runs against it. Nothing compared the fake to the binary it impersonates, so the stub's claims
about the upstream contract were unverified by construction.

The drift class was already realized, not hypothetical. PR #115 had to change the stub's sequence
comparison from `<` to `<=` because real herdr accepts only strictly greater sequences — found by
hand, during unrelated work, not by any test. The fixture also carried `protocol 19` while the
installed binary reported 20.

Adding more assertions against the fake could not have caught either one. Per this repository's
upstream-ownership rule, behavior owned by an upstream system has no valid local oracle: an
assertion written into the same patch as the fake tests the patch against itself.

## Guidance

A fake of another program is a *claim* about that program's contract. Treat the claim the way you
would treat any other untested assertion, and pin it with the only oracle that can adjudicate it —
the program itself.

### 1. Record what the fake emulates, read from the real thing

State the emulated version and protocol beside the fixture, and read both from the installed binary
rather than assuming them:

```sh
herdr --version                                    # herdr 0.8.2
herdr api snapshot | jq .result.snapshot.protocol  # 20
```

A recorded version turns "the fake is wrong" from a discovery into a comparison. It also makes the
inert-versus-live distinction explicit: the engine never reads `.protocol`, so that literal records
what the fake claims to be, not behavior under test. Correcting 19 to 20 changed no verdict, and
saying so in the comment is what stops a future reader from treating it as a live constant.

### 2. Make the real binary the oracle, and nothing in the patch

A conformance check compares the fake's output against the real program's output, captured in the
same run. Nothing on the expected side may come from the patch that writes the check.

Order matters when the fake is installed by repointing an environment variable or `PATH`: capture
the real output *before* the harness setup that redirects to the stub.

### 3. Choose the comparison depth deliberately, and say why

Pin the boundary the consumer actually reads, and stop there. Anything deeper restates a shape the
upstream program owns — which is the failure mode the check exists to avoid, not to repeat at a
finer grain. Record the chosen depth and its reason in the test, because the natural instinct of the
next reader is to deepen it.

### 4. Record divergence below that depth as an issue, not as test content

When the fake and the real thing disagree below the pinned level, the disagreement is a finding
about the fake. Encoding it in the test converts a known gap into local reimplementation of upstream
semantics. File it, name the exact keys, and state whether anything reads them today.

### 5. Skip where there is no oracle — and say which oracle is missing

Two distinct absences make the check unrunnable, and each deserves its own skip with its own reason:
the binary is not installed, and the binary is installed but has no running server to answer. A
fallback to a locally invented expected shape would turn both into the tautology the check replaces.

Note that skips remove coverage while preserving green; see
`skip-set-parity-proves-reduced-dependencies.md` for why skip identity, not the pass count, is the
thing to compare across environments.

## Why This Matters

An unverified fake is a false green with a long half-life. Every assertion that runs against it
inherits its errors silently, and the errors surface as confusing production behavior or as a
hand-found discrepancy during unrelated work — the expensive path PR #115 took.

The conformance check is cheap in a way the alternative is not. It adds one test, not one assertion
per emulated behavior, and it stays correct as the fake grows, because it compares against a moving
upstream rather than against a snapshot of what upstream looked like when someone last read the
docs.

Depth discipline is what keeps it cheap. A check that pinned the full snapshot shape would fail on
every upstream release for reasons the repository has no stake in, and the pressure to loosen it
would eventually remove it.

## When to Apply

Apply whenever a test double reproduces the observable contract of software this repository does not
own: a stub CLI, a fake HTTP service, a replayed protocol, a hand-written fixture standing in for
another tool's output format. The trigger is ownership, not size — a ten-line stub of an external
contract needs this and a large in-repo fake of your own module does not.

Do not apply it to a fake of behavior this repository owns; there the real implementation is
available and the double is usually the wrong tool. Do not deepen a conformance check to cover a
divergence you found: file the divergence instead.

## Examples

The check, `tests/bashunit/scripts_test.sh:6851` (test 1209, landed in PR #179):

```bash
function test_scripts_1209_pane_label_stub_snapshot_envelope_matches_real_herdr() {
  _bats_test_init 1209 'pane-label stub api snapshot envelope matches the installed herdr'
  command_exists herdr || skip "herdr is not installed"
  local herdr_bin real_snapshot real_keys
  herdr_bin="$(command -v herdr)"
  # A real snapshot needs a running herdr server. Without one there is no
  # oracle, so say why instead of falling back to a locally invented shape.
  real_snapshot="$("$herdr_bin" api snapshot 2>&1)" \
    || skip "real herdr returned no snapshot: $real_snapshot"
  run jq -S -c '.result | keys' <<<"$real_snapshot"
  assert_success
  real_keys="$output"

  hpl_setup                                    # repoints HERDR_SOCKET_PATH at the stub
  run env PATH="$HPL_STUB:/usr/bin:/bin" herdr api snapshot
  assert_success
  run jq -S -c '.result | keys' <<<"$output"
  assert_success
  assert_output "$real_keys"
}
```

The skip guard reuses the existing idiom at `tests/bashunit/palette_test.sh:1313`, which settled the
open question of whether a real-herdr check needed its own host-only `make` target: precedent said
no.

The recorded emulation target, `tests/helpers/herdr_pane_labels.bash:82`:

```sh
# The stub emulates the `herdr api snapshot` envelope of herdr 0.8.2, which
# reports protocol 20. Both numbers come from the installed binary rather than
# from an assumption: `herdr --version`, and
# `herdr api snapshot | jq .result.snapshot.protocol`. The engine never reads
# .protocol, so this literal records what the fake claims to be rather than
# behaviour under test.
```

**Red state, observed.** Adding a spurious top-level key to the stub's `result` turns the check red
with expected `["snapshot","type"]` against actual `["cursor","snapshot","type"]` — the expected
side visibly coming from upstream. Restoring the stub returns it to green. On macOS with herdr 0.8.2
running, the check executes rather than skips, passing with 4 assertions.

**Depth, and what sits below it.** The check pins top-level `result` keys only. At that level the
two agree, both returning `["snapshot","type"]`. One level down they diverge: the stub's
`.result.snapshot` omits `focused_pane_id`, `focused_tab_id`, `focused_workspace_id`, and `version`,
which the pane-label engine reads none of today. That is filed as
`docs/issues/2026-09-05-007-pane-label-herdr-stub-omits-four-snapshot-keys-the-real-binary-returns.md`
rather than encoded in the test.

**This is not fully closed.** The originating backlog record ("pane-label herdr stub is an
unverified protocol fake") was closed by PR #179 and pruned once this document captured its lesson,
but `2026-09-05-007` remains open and tracks those four divergent keys. The pattern here is the
conformance boundary, not a claim that the fake is now faithful.

## Related

- `semantic-regression-tests-over-source-shape.md` — the general standard this specializes. That doc
  says a test must change verdict with the protected behavior and that each contract needs one
  owner; this doc covers the case where the contract's owner is another program entirely, so the
  only valid oracle lives outside the repository.
- `generate-pua-glyphs-from-octal-printf.md` — the same oracle rule in the opposite direction: an
  oracle discriminates only while it holds a copy the thing under test cannot move, which is why the
  glyph constants in `tests/helpers/herdr_pane_labels.bash` are deliberately duplicated rather than
  extracted from the engine.
- `skip-set-parity-proves-reduced-dependencies.md` — why the two skip paths above need identity
  comparison across environments, not a pass count.
- `docs/issues/2026-09-05-007-pane-label-herdr-stub-omits-four-snapshot-keys-the-real-binary-returns.md`
  — open follow-up on the divergence one level below the pinned depth.
