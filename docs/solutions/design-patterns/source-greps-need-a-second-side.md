---
title: A source grep needs a second, independently edited side
date: 2026-09-25
category: design-patterns
module: testing
problem_type: design_pattern
component: testing_framework
severity: high
resolution_type: workflow_improvement
related_components:
  - chezmoi
  - herdr
  - ci
applies_when:
  - "A test searches a script, template, config or document for a token instead of running it"
  - "The artifact under test cannot be executed here, so a grep looks like the only option"
  - "Deciding whether an absence assertion over file text is worth keeping"
  - "Retiring a grep whose subject belongs to an upstream repository"
  - "Writing a static lint where the literal shape itself is the contract"
symptoms:
  - "A harmless re-indent, rename or comment edit turns a test red"
  - "Commenting out the matched line leaves the test green"
  - "A flag renamed in a CLI leaves the document that names it still matching"
  - "The grepped file is installed from another repository, so no local change can move it"
  - "An absence assertion runs against a section the file never had, and cannot fail"
tags:
  - source-shape
  - semantic-tests
  - two-sided-contracts
  - absence-assertions
  - upstream-ownership
  - bashunit
---

# A source grep needs a second, independently edited side

## Context

The 2026-08-24 corpus audit (#326) found source-shape greps scattered across every suite: a smoke
test searching `~/.local/bin/herdr-pane-labels` for octal escape literals and a `herdr pane rename`
call count; a one-sided grep of `child-agent-contract.md` for the `herdr-child reap --to <alias>
--pane <pane-id>` line agents copy out of it; an unanchored search of `config.toml` for
`seigi.command-palette.open`; absence checks over plugin names in a rendered settings template; a
`readFileSync` of `index.ts` looking for one exact line inside a `catch` clause.

Each failed in both directions at once. The palette grep passed on a commented-out line, on a line
that had drifted outside any `[[keys.command]]` table, and on an entry with no key at all. The reap
grep protected the document's wording rather than the agreement the document describes: rename the
flag in `herdr-child` and the old text still matched. The label-writer grep went red on an upstream
refactor from octal to hex escapes and green on a writer that had stopped working, because the
engine was never run — and that script is installed from `Seigiard/herdr-pane-labels`, so nothing
in this repository could have made it move.

The eleven per-range fixes (#327–#337) retired the whole class. What they converged on is not
"never grep a file" — several greps survived, and one static lint was kept deliberately. It is a
rule about what a grep is allowed to be *for*.

## Guidance

A grep over file text is legitimate when it **derives one side of a relationship** and the
assertion resolves that side against a second side that is edited separately. It is a false green
when it **freezes a token** and calls the match a verdict.

Work through these in order and stop at the first that applies.

### 1. Run it

If the artifact executes or renders, the grep is the wrong instrument. Run the script, render the
template, dispatch the event, and assert the exit status before the output. `run bash "$script"`
with `assert_failure 2` distinguishes a tool that rejected the input from one that died on the way;
a grep cannot. Where an installer is too destructive to run, render it and assert on the rendered
artifact, which is the thing a later step actually consumes — not the template's source text.

### 2. Close the loop against a second side

When execution is impossible, make the check two-sided. Derive a set from one file and resolve every
member of it against the other side, so that a drift on either side turns the test red and neither
side can be edited to satisfy it alone:

- A document that names a CLI invocation versus that CLI's own usage banner, extracted with the same
  regex and compared for equality (`smoke_test.sh` 1052).
- A `.chezmoiignore` platform block versus `chezmoi managed` on this host (`platform_test.sh`).
- Every `include "..."` in an install template versus a render that would error on a missing path
  (`templates_test.sh` 027).
- Every `run = "plugin X"` keymap versus the plugin entrypoint on disk (`templates_test.sh` 016).
- kitty's `send_text` bindings versus ghostty's, chord for chord, after normalising the two spelling
  conventions (`smoke_test.sh` 027).
- The mapping table in `herdr-peer-launch.md` versus the executable's own case table
  (`external_leg_pair_test.sh`).

Two properties make these work. The derived side is **not transcribed into the test** — copying the
list into the test file puts expectation and implementation in the same patch. And the extraction
**fails loudly when it finds nothing**: `set -o pipefail` with grep's own exit status, or an explicit
`[ -n "$tokens" ] || fail`, so an empty match is a failure rather than a vacuous comparison of two
empty strings.

### 3. Parse the structure, not the substring

Where the file is the whole contract because an external tool reads it verbatim, parse it the way
that tool does. The palette check now splits `[[keys.command]]` tables, reads each table's fields,
and requires that every table naming the action carries a non-empty `key` and the `plugin_action`
type — so a commented-out line, a drifted entry and a keyless entry all fail. Which chord is bound
stays unpinned, because that is the user's preference and not a contract.

### 4. Delete it and name the owner

Behavior owned by an upstream repository has no local oracle, and no assertion written here can
adjudicate it. Delete the check, name the contract it claimed to cover, and name the test that owns
what this repository actually controls — usually the deployment half: that the package is installed
from the expected source and that its runtime landed where the shell resolves it.

### The narrow exception: a static lint

A layering rule has no runtime to observe. "No policy module names a client", "no import edge
between the dispatch core and the shared module" — the literal shape *is* the contract, and there is
no execution that can reveal a violation. Such a lint stays, under three conditions:

1. It carries a **discriminating control**: a fixture directory with one compliant and one offending
   file, asserting that the scanner reports exactly the offender. Without it the scan can report an
   empty result because it reads nothing, and an empty result is what the real assertion wants.
2. It **states its limits** in a comment — which violations the pattern also flags, and which it
   misses.
3. It says **where it belongs instead**, so it moves to the lint gate when one arrives.

### Absence assertions

Removing a dependency, a plugin, a hook or a config entry does not justify asserting that its name
stays out of a file. Such an assertion often cannot fail at all: three retirement checks in
`templates_test.sh` 031 ran `jq -e ... | has(...)` against `null` and exited non-zero whatever the
settings said. Assert the capability that remains, or exercise the real transition that clears the
stale state. A `refute` over *runtime or rendered output* is a different thing and stays: refuting a
`plugin link` line in a recorded call log proves the migration did not re-register a local plugin.

## Why This Matters

A source grep is the cheapest thing to write and the most expensive thing to keep. It reads as
coverage in the pass count, so the next investigation stops there — while it goes red on every
harmless refactor, which trains everyone to edit the test rather than read it.

The two-sided form costs one extra extraction and buys a check that no single edit can satisfy. That
is the difference between a test that watches a file and a test that watches an agreement.

## Examples

From #327–#337 and the #340 sweep:

- **Deleted, owner named:** the `herdr-pane-labels` label-writer contract and its helper. Contract:
  the internals of an upstream script. Owners for the half this repository controls: smoke 1060
  (installed from the expected GitHub source) and 1061 (runtime, aliases and version file deployed).
- **Made two-sided:** smoke 1052, which now extracts the `herdr-child reap` invocation from the
  contract document *and* from the tool's own usage banner, asserts exit 2 first, and compares the
  two.
- **Parsed instead of grepped:** smoke 006, which reports `not dispatchable: <key>`, `no table binds
  seigi.command-palette.open`, or the success sentence — three distinguishable verdicts where a grep
  had one.
- **Kept as a lint:** `agent-hooks-core.test.ts` "no shipped policy module references a client" and
  `agents-local-opencode-plugin.test.ts` "the shipped core and shared module import nothing from
  each other", each preceded by its own scanner-detects-the-offender control.
- **Kept as an external literal:** `test_ci_workflow.py` asserting `timeout-minutes` per job. GitHub
  Actions is the consumer, the workflow file is the whole interface, and no local run observes it.

The 2026-09-25 sweep over the full corpus — `tests/bashunit/*_test.sh`, `tests/helpers/`,
`tests/test_*.py`, `tests/*.test.ts` — found no remaining one-sided source grep. Every surviving
grep either reads a recorded call log, reads rendered output, or derives one side of a two-sided
comparison.

## When to Apply

Apply when a test is about to read a file rather than run something, and when reviewing one that
already does. The question to ask is not "does this file contain the right text" but "what would
have to change for this assertion to be wrong, and can one person change it in one place".

## Related

- `semantic-regression-tests-over-source-shape.md` — the parent rule. It owns the test-oracle gate,
  the contract-boundary choice and the red-before-green requirement; this document owns the narrower
  question of what makes a text-reading check legitimate when no boundary can be executed.
- `expectations-cannot-share-a-source-with-the-code.md` — the sibling rule for the other way an
  expectation loses its second side: computed by the code under test rather than read off a file.
- `fakes-need-the-real-binary-as-oracle.md` — the mirror case: a fake reproduces an upstream
  contract, so the real binary has to be the second side.
- `~/.claude/rules/testing.md` — the false-green rules that apply in every repository, including the
  absence-assertion rule this document applies to source text.
- `docs/agent-verification.md` — which checks to run, and when their evidence is still valid.
