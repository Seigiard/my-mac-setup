---
description: "test-worth — whether each test can fail for the right reason, earns its place, and is still about the code as it now stands"
---
## Lens: test-worth

Review every test the change adds, edits, deletes or leaves behind. `tests` asks whether a test
exists where a defect can hide; this lens asks whether the tests that exist are worth keeping. A
test that looks right and cannot fail is a permanent false signal every later reviewer trusts, and
it costs more than the gap it covers.

For each test, write down the one edit to production code that turns it red. The test earns its
place when that edit is one someone would notice in use. Done when every test in the change has its
red-making edit written down, or is reported.

A test that cannot go red takes one of five shapes, the ones generated tests take most:

- **tautology** — the assertion compares a value the test itself constructed: a literal it built, a
  mock it configured, a stub's return handed back through the code under test. The extreme form
  never calls the code under test and re-implements it in the test file. A mock configured at the
  top of the file and asserted at the bottom is still this
- **the oracle mirrors the implementation** — the expected value is derived by running the same
  logic, template, transform or helper the production path runs: green by construction, and still
  green when both are wrong. The expected value comes from outside the patch: a literal the contract
  fixes, a reproduced failure, a documented interface
- **weak assertion** — greater than zero, not null, defined, truthy, contains, non-empty, an exit
  code alone, where an exact value is known. Loosening is legitimate only where the surrounding
  output is genuinely unstable, and then the matched text must itself change when the behavior breaks
- **conditional assertion path** — an `if` or `case` choosing between expectations, a catch that
  swallows, an `|| true`, errexit switched off around the command under test. One deterministic
  path; a skip only on a named environment precondition, left visible
- **happy path only** — the inputs that fail differently, empty, single element, boundary,
  duplicated, malformed, the error path, with nothing exercising them. Report the one whose failure
  someone would notice and state its symptom, never an inventory

A test stops earning its place in these:

- **output before status** — output inspected without first asserting the command succeeded, so a
  crash that prints the expected string passes. A rejection fixture with no valid control beside it,
  so "bad input is refused" cannot be told from a tool that refuses everything
- **shape instead of behavior** — an assertion that a file contains a phrase, a function has a name,
  a line matches a pattern: pinned to how the source is written rather than what it does, so a
  correct rewrite goes red and a wrong one stays green
- **never seen red** — a regression test with no evidence it failed against the regression. Report
  it as uncalibrated, and the coverage it claims as unproven
- **stale** — a test asserting behavior the change removed or renamed, kept green by its own setup; a
  skip whose stated reason no longer holds; a test that now duplicates another's contract without
  naming which one owns it
- **evidence removed to reach green** — a test deleted, skipped, weakened or narrowed in the same
  change that made it fail. A red test is a defect report; deleting one needs the contract named and
  the test that now owns it
- **coverage for its own sake** — a test added because coverage is expected, pinning nothing that
  can regress. Zero new tests is a legitimate outcome

Rate by the defect the red-making edit would let through: minor when contained, major when the suite
exists to catch exactly that. A finding names that edit; a remark on how a test is written belongs
to `quality`.

Leave alone: setup repeated across tests for readability, a plain assertion on a trivial pure
function, a hand-written literal that happens to equal what the code computes.
