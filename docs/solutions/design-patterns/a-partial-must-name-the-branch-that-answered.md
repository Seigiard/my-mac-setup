---
title: A partial match must name the branch that answered
date: 2026-09-25
category: design-patterns
module: testing
problem_type: design_pattern
component: testing_framework
severity: high
resolution_type: workflow_improvement
related_components:
  - herdr
  - chezmoi
  - ci
applies_when:
  - "Asserting a command's diagnostic, refusal or rendered output"
  - "Choosing between assert_output, assert_output --partial and assert_line"
  - "Splitting one message across several toContain, assertIn or --partial checks"
  - "Writing a refutation beside an assertion on the same output"
  - "Matching output that carries a UUID, a temporary path or a timestamp"
symptoms:
  - "Several partials sit under one run, each matching a fragment of one line"
  - "A gate's message is matched without the value it refused"
  - "Two gates print messages that share a prefix, and the test matches the prefix"
  - "A refutation names one string while the assertion beside it is already exact"
  - "A substring assertion on a list passes when most of the list is missing"
tags:
  - false-green
  - exact-assertions
  - partial-matching
  - diagnostics
  - bashunit
  - regression-tests
---

# A partial match must name the branch that answered

## Context

The 2026-09-25 corpus audit (#326) counted around 450 substring assertions across the bashunit,
Python and TypeScript suites — `assert_output --partial`, `assert_stderr --partial`, `toContain`,
`assertIn`. Most were fine: chezmoi's template-error framing, gitleaks' timestamped progress lines
and ssh-keygen's output are genuinely unstable, and matching a stable phrase inside them is the
right call.

The defective ones shared a shape the count alone hid. They were not *one loose match on unstable
output*; they were **several partials under one `run`, each holding a fragment of a single
deterministic line**. Nothing in that arrangement binds the fragments to the same line, and nothing
binds the line to the gate under test:

- `chezmoi-unattended` prints one line and exits 2 from every gate. Two of them begin
  `MMS_DISPOSABLE_HOME must equal 1` — one for the full-fixture profile, one for a write-capable
  command. A test matching the shared prefix passed when the wrong gate answered.
- `herdr-child`'s partial-success diagnostic names the pane, the terminal and the tab a caller has
  to clean up by hand. Three partials matched the status and the pane; dropping the terminal from
  the message left every one of them green.
- The wrapper's untracked-creation line carries `workspace_created` and `tab_created` after the
  coordinates. Seven partials covered the rest of the line and those two fields were asserted by
  nothing at all.
- `skills sync` prints a six-row plan. Six partials could not see a duplicated row, a row pairing
  the wrong source with the wrong skill, or drift reported before the installs.
- `ask.sh` relays a 250-line report. `--partial 'report line 1'` is also satisfied by
  `report line 100`, so a relay that forwarded two lines passed.

Every one of these was demonstrated: the mutation that hid behind the partials was injected, the
old assertions were re-run under it and stayed green, and the replacement went red.

## Guidance

### Decide by the output, not by the habit

Ask what the command actually prints, then pick the narrowest assertion that covers all of it:

1. **One deterministic line or block** → `assert_output` / `assert_stderr` / `toEqual` on the
   whole thing. Most diagnostics in this repository are one line from one `fail()`-style helper, so
   this is the common case, not the exotic one.
2. **Deterministic except for a nonce** — a UUID, a generation hash, a pid → one whole-line
   `--regexp` with the nonce wildcarded (`[0-9a-f-]{36}`), or read the nonce back from the artifact
   that recorded it and assert the exact line. Both keep every other field pinned.
3. **A known line inside unstable surroundings** → `assert_line` (exact line, any position), not
   `--partial`. A substring match also fires inside a longer line; a line match does not.
4. **Genuinely unstable text around a stable phrase** → `--partial`, and then the phrase has to be
   the *whole* discriminating clause, with the program prefix and the refused value in it. Say
   *why* in a comment, so the next reader does not have to re-derive the judgement.

### Never split one line across several partials

If two partials sit under one `run` and both belong to the same line, they are one assertion
written twice as weakly. Join them. If they belong to different lines of a deterministic block,
assert the block. The split form cannot see reordering, duplication, an extra line, or a fragment
that moved to a different message — and those are exactly the regressions a diagnostic suffers.

### A partial must carry the value, not only the verb

`invalid machine_role` does not say which role was refused. `has no authorized keys` does not say
whose. `pin left unchanged` does not say which pin or which tag. Each of these passed while a
*neighbouring* gate answered instead. Put the refused value and the accepted set in the match; they
are the part an operator reads, and the part that changes when the wrong branch runs.

### An exact assertion subsumes the refutation beside it

`assert_output 'X'` already proves the output is not `X` plus a leaked secret, not `X` plus a stale
row, not `X` plus a second status line. A `refute_output --partial` next to it speaks for one string
and implies the others are fine. Delete it and say so; keep a refutation only where the assertion
above it is itself partial.

### Where the loose form stays

Loosen deliberately, and leave the reason in the test:

- Output owned by a tool we route to — chezmoi's `template: ...:N:M: executing ...` framing,
  gitleaks' timing lines, `op`'s errors. Match the phrase our code contributes.
- A value the fixture makes enormous rather than meaningful — a 96 KiB oversized path. Match the
  destination prefix, which still proves the gate named the right target.
- Text a consumer does not read verbatim — a human-facing skip message. Match the actionable token
  and say that the prose is not a contract.
- Upstream detail with no local oracle — a Python `OSError` string, an upstream version number.
  Assert our sentence, not theirs.

### Direction-only checks are the same defect

`[ -n "$x" ]`, `refute_output ''`, `length > 0`, `toBeDefined`, `assertTrue(x)` accept every wrong
value that is not empty. They are legitimate as **guards** — placed before a loop or a filter, with
a comment saying the assertion below would be vacuous without them — and illegitimate as the
verdict. If one is carrying the verdict, the exact value is almost always knowable from the fixture
the test itself wrote.

## Why This Matters

A diagnostic exists so that whoever reads it can act: close the preserved pane, fetch the checksum
by hand, fix the role in the config. A partial that matches the verb but not the value keeps the
test green through exactly the regression that makes the message useless — and a message that has
stopped naming its subject looks, from the suite, identical to one that still does.

Splitting a line into fragments also inverts what a reader assumes. Five assertions look like more
coverage than one. They are less: one exact match fails on everything the five miss, and on
everything they were never written to look at.

## Examples

From the 2026-09-25 sweep (#342), each observed red under an injected regression and green without
it:

- `chezmoi_unattended_test.sh` — eleven gates moved to the exact `chezmoi-unattended: <message>`
  line plus `assert_failure 2`; test 010's five partials plus a secret refutation became one exact
  two-line notice block.
- `herdr_resource_tree_test.sh` — six clusters of 2–7 partials on the untracked-creation diagnostic
  became one whole-line `--regexp` each, which also pinned `workspace_created`/`tab_created` for the
  first time; test 015's `--context` projection became one exact ten-line render, and the OpenCode
  plugin now compares against that same render instead of four of its own substrings.
- `scripts_test.sh` — the `herdr-child` partial-success, arm-failure, stall and timeout envelopes;
  the `skills sync` plan; the `ask.sh` relay; eight `herdr-agent-limits` renders; the
  resource-context sentence; the 1Password modifier's stderr pair.
- `templates_test.sh` — the four role and authorized-keys gates now name the refused value.
- TypeScript — two brew notifications and the local-instructions warning became whole-object
  `toEqual`.
- Python — the post-apply runner's two rejections now name the fixture file, so rejecting the valid
  control no longer passes.

**Kept, with the reason written in the test:** gitleaks' timing lines, the 96 KiB oversized-target
path, the Python `OSError` detail in the intent-recording failure, `executor --version`, the
truncation notice whose cut point is the implementation's choice, and the brew-entry
`assert_line --partial` matches whose trailing comments are prose.

## When to Apply

Apply when writing or reviewing any assertion on a command's output. The question is not "does the
output contain this text" but "which branch could print something that satisfies this, and would I
be able to tell". If more than one branch qualifies, the match is too short.

## Related

- `semantic-regression-tests-over-source-shape.md` — the parent rule. Its "Precision and shape are
  separate axes" paragraph states the principle; this document is how it is applied to substring
  matching, and what the legitimate exceptions look like here.
- `source-greps-need-a-second-side.md` — the sibling case: what makes a text-reading check
  legitimate when the artifact cannot be executed here.
- `~/.claude/rules/testing.md` — the false-green rules that apply in every repository, including
  "assert the exact value" and "assert status before output".
- `docs/agent-verification.md` — which checks to run, and when their evidence is still valid.
