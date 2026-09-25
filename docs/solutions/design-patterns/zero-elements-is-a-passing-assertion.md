---
title: Zero elements is a passing assertion
date: 2026-09-25
category: design-patterns
module: testing
problem_type: design_pattern
component: testing_framework
severity: high
resolution_type: workflow_improvement
related_components:
  - agent-hooks
  - ci
  - chezmoi
  - herdr
applies_when:
  - "Putting an assertion inside a for loop, a while read, an every/all/any, or a subTest"
  - "Building the iterated collection with a filter, a glob, a regex findall or a parser"
  - "Writing a helper that calls a handler the unit under test was supposed to register"
  - "Reviewing a test whose loop body holds the only assertion in it"
  - "Deciding whether a lower-bound guard on a collection is enough"
symptoms:
  - "A test passes with a higher assertion count than the loop could possibly have produced"
  - "Deleting the registration, the route or the fixture leaves the suite green"
  - "A filter that stops matching shortens the run instead of failing it"
  - "An `every` or `all` returns true over an empty list"
  - "A helper returns the same value for 'the handler allowed it' and 'no handler exists'"
  - "A loop body opens with a `continue` that no assertion accounts for"
tags:
  - false-green
  - vacuous-truth
  - cardinality
  - loops
  - fixtures
  - bashunit
  - bun-test
---

# Zero elements is a passing assertion

## Context

The 2026-09-25 corpus audit (#326) found a family of tests whose assertions lived inside a loop over
a collection the test itself computed. Over zero elements the loop runs zero assertions, the test
reports green, and the report shows nothing unusual — a suite summary counts tests, not the
assertions a test was supposed to make.

The same shape has a quieter and more common variant. The collection is not empty, it is *short*: a
filter stopped matching one member, a parser missed one section, a wire table lost one route. The
loop still runs, the remaining members still pass, and the coverage that disappeared is the coverage
nobody notices is gone.

Concrete instances from this repository, all since fixed:

- `runCanaries` results were checked with `results.every(ok)`. A session-level disable that produced
  an empty canary set satisfied it, so a registry with no live routes read as a healthy one (#336).
- `herdr_resource_tree_test.sh` 006 and 007 asserted `creator_session is None` across every pane the
  CLI returned. An empty tree — the exact shape a broken snapshot produces — passed both (#332).
- The pi adapter's `callToolCall` returned the handler's result, and pi reads `undefined` as allow.
  With no handler registered it returned `undefined` too, so a broken `$HOME` symlink or a renamed
  export left four allow tests green while the extension enforced nothing (#337).
- The Agent Intercom loader tests asserted `{}` for "no-op without importing the package". A loader
  that ignored its gate, attempted the import and swallowed the failure returned the same `{}` (#337).
- `platform_test.sh` 002 matched darwin-only basenames by substring across the tree and required only
  that the count of matched entries was above zero (#334).
- `terminal.json`'s theme check ran `[.vars[]] | all(...)` and then required a derived list to be
  empty. Both hold over an empty `vars` and an empty `colors`, which is what a truncated theme file
  looks like (this sweep, #343).

## Guidance

### Gate the collection before the loop, not inside it

The assertion that the collection is the right size belongs **above** the loop, as its own statement.
Inside the loop it is one more thing that does not run.

```python
invocations = self.wrapper_invocations("full", jobs="3")
self.assertEqual([Path(argv[-1]).name for argv in invocations], FULL_MODE_ORDER)
for argv in invocations:
    ...
```

The gate is not decoration for the loop that follows: it is the statement that the loop had a subject.

### Prefer the members to a count, and an exact count to a lower bound

Three forms, in descending order of what they can catch:

1. **The member list.** `expect(compared).toEqual([...four route strings...])` says which routes were
   compared. A route that drops out names itself in the diff.
2. **The exact count.** `[shared.length, bashCount, fffCount]` against `[19, 14, 5]`. Cheaper to write
   when the member names carry no information, and still red when one member disappears.
3. **A lower bound.** `length > 0`, `assertTrue(names)`, `-n "$entries"`. This catches only the fully
   degenerate case.

A lower bound is the right answer in exactly one situation: when the size of the collection is a
legitimate configuration choice that must not need a test edit. The number of registry artifacts in
`package-lock.json` grows with every dependency; the `instructions` list in `opencode.json` is the
user's; the includes in an install script are the script's own business. There, pin non-emptiness,
and write down in a comment *why* the exact form would be wrong. Everywhere else — the routes of a
policy, the jobs of a workflow, the services of a compose file, the batches of a launcher — the size
is part of the contract and belongs in the assertion.

### The gate has to come from the other side

The collection is usually produced by something the test wrote: a wire table, a regex, a glob. A gate
computed the same way restates it. `shared` in the adapter suites is selected by that file's own
`PI_WIRE`/`OPENCODE_WIRE` table, so the gate counts the corpus's `bash` and `fff-grep` fixtures
instead — the side that would not move if the wire table lost a route.

When there is no second side, look for one a layer out: `chezmoi_unattended_test.sh` 0101 asserts one
recorded argv size **per final invocation**, and the invocation log is written by a different branch
of the same controlled child than the size log. `source-greps-need-a-second-side.md` owns this form
in full.

### The failure to design against is `fewer`, not `zero`

An empty collection is the easy case and often impossible in practice. What actually happens is that
one member stops matching. That is why the mutation used to calibrate the gate should **shrink** the
collection rather than empty it:

- rename a workflow job (`lint` → `lint-shell`): the parser still finds three, and every lower-bound
  guard stays green;
- break one job's launcher spelling (`-- apply` → `--apply`): the applying set drops from two to one,
  and `assertGreaterEqual(len(applying), 2)` is the only thing that notices;
- drop one fixture from the corpus: 19 becomes 18, and `toBeGreaterThan(0)` never moves.

If the mutation leaves the suite green, the guard was a lower bound pretending to be a gate.

### A `continue` is a gate you did not assert

`[ -d "$sub" ] || continue`, `if not match: continue`, `if clients.length < 2 continue` — each one
makes the loop body conditional on data, which means the count of assertions the test makes depends
on the collection's shape. That is fine, and it is exactly why the shape has to be asserted. Where a
`continue` filters, collect what survived it and assert that list, the way the cross-client parity
test now collects `${policy.name}: ${clients.join("/")}` for every policy it reached.

### A helper must not answer for the unit that never registered

The loop case has a twin in dispatch helpers. When a test calls a handler the unit under test was
supposed to register, and the absent-handler value coincides with the passing value, the helper
reports success for a unit that did nothing:

- pi reads `undefined` from a `tool_call` handler as allow, and an unregistered handler is `undefined`;
- an opencode `callBefore` that catches everything and returns the message turns a missing hook into
  a string that merely fails to equal the deny text, so the diagnosis arrives as a type error from
  somewhere else.

The rule is the same one as above, applied to a collection of size one: assert that the handler
exists before asking it anything.

```ts
expect(host.handlers["tool_call"]).toBeTypeOf("function");
```

This is not a second assertion competing with the test's own. It is the statement that there was
something to assert about — and, unlike a `TypeError` surfacing three frames later, it names the
missing registration.

## Why This Matters

A vacuous loop is indistinguishable from coverage at every level a reader normally checks: the test
name describes the contract, the body contains the right assertion, the suite is green. Only the
assertion count would show it, and nobody reads assertion counts.

It is also the shape that degrades quietly over time. Nothing has to be wrong at the moment it is
written — the corpus is full, the registry is live, the parser matches. It becomes a false green
later, at the moment the thing it was protecting breaks, which is precisely when it was supposed to
speak.

## Examples

Fixed across #332, #334, #336, #337 and the #343 sweep:

- **Exact member lists in place of `every`:** the selfcheck canary tests assert the whole
  `policy@client: ok detail` list; an empty result set now fails with three missing entries (#336).
- **The fixture set pinned before the tree walk:** `herdr_resource_tree_test.sh` 006 and 007 assert
  the workspace, tab and pane id sets before checking `creator_session`, with the reason written
  beside them (#332).
- **A handler guard in the dispatch helper:** `callToolCall` and `callBefore` require a registered
  handler; breaking the core import now fails with `Received type: "undefined"` rather than reading
  as four allows (#337, and the opencode sibling in #343).
- **An import marker instead of an indistinguishable `{}`:** the loader tests plant a package whose
  module scope writes a file, so "the gate fired" and "the import failed and was swallowed" are
  different observations (#337).
- **Two sides, complete sets:** `platform_test.sh` derives the darwin ignore block's entries and
  asserts the complete unmanaged set against one named exception, and its reader exits non-zero
  rather than emitting a junk entry (#334).
- **Cardinality tied to an independent counter:** `chezmoi_unattended_test.sh` 0101 requires one
  serialized-size record per final invocation; a short record file now fails with `expected : 3,
  actual : 1` (#343).
- **Named jobs and services instead of `>= 2`:** the CI workflow's three jobs, its two applying jobs
  and compose's three services are asserted by name, so a renamed job or a broken launcher spelling
  fails the gate instead of shortening the loop (#343).
- **Anti-vacuity gates on a jq `all`:** `terminal.json`'s `vars` and `colors` must be non-empty
  before the palette property is checked, matching the guard the sibling Claude Code theme test
  already carried (#343).

## When to Apply

Apply when an assertion sits inside any iteration — a `for`, a `while read`, a `subTest`, an
`every`, an `all`, a `filter(...).toEqual([])` — and whenever a test helper reaches for a handler,
hook or route that the code under test is responsible for installing. The question to put to the
loop is not "does the body assert the right thing" but "what is the smallest change that would make
this body run fewer times, and would anything fail".

## Related

- `semantic-regression-tests-over-source-shape.md` — the parent rule. It owns the test-oracle gate,
  the contract-boundary choice and the red-before-green requirement; this document owns the case
  where the assertion is correct and simply never runs.
- `expectations-cannot-share-a-source-with-the-code.md` — the sibling false green: an assertion that
  runs, and agrees with the implementation because both compute the same thing.
- `source-greps-need-a-second-side.md` — the two-sided form this document's gates depend on, and why
  an extraction that matches nothing has to fail loudly.
- `skip-set-parity-proves-reduced-dependencies.md` — the same loss one level up: coverage that
  disappears through skips rather than through empty collections, with a green suite either way.
- `~/.claude/rules/testing.md` — the false-green rules that apply in every repository, including the
  requirement that a test be observed red before it counts as calibrated.
