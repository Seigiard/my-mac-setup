---
title: An expected value cannot share a source with the code that produces it
date: 2026-09-25
category: design-patterns
module: testing
problem_type: design_pattern
component: testing_framework
severity: high
resolution_type: workflow_improvement
related_components:
  - agent-hooks
  - chezmoi
  - herdr
applies_when:
  - "Writing the expected side of an assertion for a transform, encoder, formatter or path scheme"
  - "Reaching for a test helper that computes what the code under test computes"
  - "Building wire-shaped input with the encoder whose parser the test exercises"
  - "Deciding whether a shared constant belongs on the input side or the expected side"
  - "Reviewing a suite whose expectations are built by a helper near the top of the file"
symptoms:
  - "A mutation of the production formula leaves the suite fully green"
  - "The expected value is a call into the module under test, or a second spelling of it"
  - "A helper named after the production function composes the text the assertion checks"
  - "A new field appears on both sides of an equality at once and no case fails"
  - "Changing the contract needs one edit in the code and one matching edit in the test"
tags:
  - false-green
  - literal-oracles
  - tautology
  - fixtures
  - provenance
  - bashunit
  - bun-test
---

# An expected value cannot share a source with the code that produces it

## Context

The 2026-08-24 corpus audit (#326) found a family of tests whose expected value was computed by the
same path as the actual value. Not copied once and left to rot — *recomputed on every run*, from the
same regex, the same helper, the same encoder, or a faithful port of the same algorithm.

Such a test is green whether the behavior is right or wrong, and it is green for a reason that no
amount of reading the assertion reveals: the two sides agree because they have to. It also inverts
the maintenance signal. A real contract change should turn a test red and make someone decide; here
it turns nothing red, while a harmless refactor of the shared formula turns everything red at once.

Concrete instances from this repository, all since fixed:

- `pins_expected_fff_bump` built the expected `.chezmoiexternal.toml` by re-running `update-pins`'s
  own four `sed -n` expressions, its asset-name substitution and its positional target/checksum
  pairing, then asked the same stub fetcher for the sums. Reversing the checksum pairing inside the
  script produced a matching wrong expectation, and the test stayed green (#331).
- `opencodeRawFor` and `piRawFor` produced each adapter's input with `normalize.encodeEvent` — the
  writers half of the module whose readers half the suite was exercising. A writer and a reader that
  agreed on `args.cmd` instead of `args.command` kept every test green while no real traffic reached
  a policy (#337).
- `zshReason()` in `fixtures.ts` repeated the line order, joiner and conditional sentences of the
  policy's own message composition, for 22 corpus cases (#336).
- `test_post_apply_suite_contract.py` re-derived the expected suite order and eligibility with a
  Python port of the runner's parser, reading the same files (#335).
- Test-side helpers re-implemented the url-safe-base64 state-key encoder in three spellings across
  the worktree-identity suite, and once more for the handoff store (#327, and the #339 sweep).

## Guidance

An expectation is sound when the production path **cannot reach its source**. There are four ways to
get there; prefer them in this order.

### 1. Write the literal

The default. Spell out the value the contract produces and put it in the assertion. A literal is
falsifiable by construction: nothing the implementation does can move it.

This is possible far more often than it looks, because test inputs are usually chosen, not
discovered. The handoff suite derived its store filenames with the hook's own encoder; but the
session ids it passes are the fixed strings `bare`, `auto`, `injected`, `neighbour`, `startup` and
`replaced`, so the filenames are six literals. The same held for the two session ids in the
worktree-identity suite. A derivation was standing in for a lookup table nobody had written down.

When the literal is long, that is information: `tests/agent-hooks-core.test.ts` spells out the
canonical `EventPayload` record and `herdr-resource-context-pi-extension.test.ts` spells out one
whole injected system prompt, marker by marker. Both are worth their length because both are the
shape a consumer reads.

### 2. Capture the fixture once and record where it came from

Where the value is a snapshot of something that existed — a legacy schema, a recorded response, a
wire sample observed against a deployed server — commit it with its provenance in a comment, and say
explicitly that it must not be refreshed from the current source.

`herdr_resource_tree_test.sh` tests 007 and 011 hold the pre-migration `operations` table as an
older `herdr-resource-tree` shipped it. The comment names it as frozen by history and forbids
updating it to match the source, because the whole point of test 011 is that the CLI adds the
columns it now writes. A fixture like that is only safe while the note survives; without the note the
next reader repairs the "stale" schema and deletes the test's subject.

### 3. Resolve against a second, independently edited side

Where no literal exists and nothing was captured, derive the expectation from a different artifact
than the one under test, and make both sides fail the comparison. `external_leg_pair_test.sh` reads
the complexity-to-model table out of `herdr-peer-launch.md` rather than out of the executable's own
`case`. `platform_test.sh` reads a `.chezmoiignore` platform block and resolves every entry against
`chezmoi managed` on this host. `smoke_test.sh` 016 runs the chezmoi source modifier and checks the
applied `settings.json` against it, so the two sides are source-of-truth and deployment.

`source-greps-need-a-second-side.md` owns this form in full, including the two properties it needs:
the derived side is not transcribed into the test, and the extraction fails loudly when it matches
nothing.

### 4. Keep the derivation as plumbing — and give the formula one literal owner

Some keys cannot be literals. A repository state path encodes a `mktemp` directory, so the test that
looks it up has to encode that directory too. Deleting the helper is not an option and neither is a
literal.

What is available is to make the formula itself answer to a literal somewhere. `scripts_test.sh`
test 1206 runs both shipped key encoders — `encode_key` in `herdr-worktree-state.sh` and
`context_usage_encode_key` in `context-usage.sh` — against three hand-written vectors: a plain id, a
string whose base64 carries `+`, `/` and padding at once, and a path long enough that GNU `base64`
wraps it. Thirty-odd derived path lookups are then plumbing calibrated by one test, and a change to
the encoding is a named failure rather than thirty opaque ones.

Two conditions make this honest: the helper must be a **single** definition (three spellings of one
formula drift apart), and its comment must **name the test that owns the formula**, so the next
reader knows the derivation is not the last word.

### Input side versus expected side

A production constant used to *build an input* is fine; the same constant on the *expected side* is
the defect. `agents-local-opencode-plugin.test.ts` sizes an over-cap fixture with
`shared.MAX_LOCAL_INSTRUCTIONS_BYTES` and then asserts the literal `51200` in the warning text. The
first is a way to reach the branch, the second is the verdict.

The same split rescues the encoder-driven parity test in `agent-hooks-core.test.ts`: `encodeEvent`
generates N dialects of one payload, and the assertion is that the N decisions agree. The wire
spellings themselves are owned elsewhere, by hand-written `raw` samples per client. That is
legitimate, and the comment says so — an encoder on the input side of a *relational* property is not
the same thing as an encoder producing the value under test.

### Prove it the only way that counts

A derived expectation cannot be diagnosed by reading. Mutate the shared formula and run:

- If the suite stays green, you have found a false green, and the mutation is the evidence to record.
- If it goes red, the two spellings were independent after all. Say so plainly rather than claiming
  a fix you did not make.

The mutation has to be **symmetric** — applied everywhere the formula lives. Adding a canonical field
to `emptyPayload()` alone left the core dialect loop red; adding it to `payloadOf()` as well left all
53 tests green, and that second run is what proved the expectation was sharing a source.

## Why This Matters

A missing test is a gap someone can see. This one reads as coverage, survives review, and answers
every question you put to it with a pass. It is the single most expensive shape in a suite, because
it is the one that stops the next investigation.

It is also the shape the tooling cannot catch. The retired `test-oracle-guard` write-path hook
inspected each proposed edit in isolation, and a tautological *positive* assertion is only visible
with both sides of the diff in view. Until a reviewer-side check ships, this document and `CLAUDE.md`
are the enforcement.

## Examples

Fixed across #327–#337 and the #339 sweep:

- **Literal, keyed by name:** `pins_expected_fff_bump` now builds the expected externals from four
  fixed per-platform sums and the served tag, pairing each sum with the target named on the line
  above it — no parsing shared with the script (#331).
- **Hand-written wire tables:** `OPENCODE_WIRE` and `PI_WIRE` replaced the encoder-derived helpers.
  A reader/writer co-drift mutation now fails 3 and 2 tests; under the old helpers it failed none
  (#337).
- **Literal where composition is the contract:** the readonly-only, tied-only and both-sentences zsh
  block texts are spelled out in `fixtures.ts`. A shared composition mistake left the six
  helper-composed cases green and turned exactly those three red (#336).
- **Synthetic subject:** `test_post_apply_suite_contract.py` declares a four-file suite the runner has
  never seen, with declared order 10/20/30 chosen to disagree with both file order and alphabetical
  order, so neither can be mistaken for the contract (#335).
- **Frozen fixture with provenance:** the pre-migration `operations` schema in
  `herdr_resource_tree_test.sh` 007 and 011 (#332).
- **Plumbing plus a literal owner:** `hwi_encode_state_key` survives for `mktemp`-derived repository
  paths; `hwi_session_state_path` and `handoff_store_path` became literal tables; `scripts_test.sh`
  1206 pins the encoding for both shipped libraries (#339).

The 2026-09-25 sweep over `tests/bashunit/*_test.sh`, `tests/helpers/`, `tests/test_*.py` and
`tests/*.test.ts` found no remaining expectation computed by the code under test. The derivations
that survive are on the input side, or are second sides of a two-sided comparison, or are plumbing
whose formula test 1206 owns.

## When to Apply

Apply when writing or reviewing the expected side of any assertion over a transform, and whenever a
test file defines a helper whose name echoes a production function. The question is not "is this
value correct" but "what would have to be wrong for this assertion to fail, and can the same mistake
reach both sides of it".

## Related

- `semantic-regression-tests-over-source-shape.md` — the parent rule. It owns the test-oracle gate,
  the contract-boundary choice and the red-before-green requirement; this document owns the narrower
  question of where the expected value is allowed to come from.
- `source-greps-need-a-second-side.md` — the sibling case: what makes a text-reading check legitimate
  when the artifact cannot be executed here. Its two-sided form is option 3 above.
- `fakes-need-the-real-binary-as-oracle.md` — the same problem one layer out: a test double
  reproducing another program's contract cannot be adjudicated by anything written beside it.
- `~/.claude/rules/testing.md` — the false-green rules that apply in every repository, including the
  ban on values re-derived by running the logic under test.
