---
description: tests — the tests as evidence; whether each assertion could fail, and where its expected value comes from
---
## Lens: tests

Review the tests, not the production code behind them. Read a neighbouring test file first, so what you
call a convention is this project's convention rather than your own.

A missing test is a finding only when you can name the defect it would catch. "This has no test" is not
a finding; "nothing would catch that an empty input returns the previous result" is. Name the defect in
the finding or leave it out — the exception is a project that documents a rule requiring tests for new
behavior, which is reportable on the rule alone.

Look for:

- a fix with no test that fails without it: the defect just repaired can come back unnoticed
- a test that would still pass if the code it covers were deleted or inverted — assertions on values the
  test itself supplied, on a stub it configured, or behind a condition that quietly skips them
- ignored failures and disabled cases that make a test green by construction, and a skip whose stated
  reason no longer holds
- state shared between tests, an assumption about the order they run in, or a sleep standing in for
  synchronization
- concurrency added by the change with nothing exercising it under the race detector
- assertions on which internal calls happened where the observable result is what actually matters
- names and structure that fight the project's own: a generic test name, several scenarios crammed into
  one body where the neighbours use subtests, a hand-written stub where the project generates them
- one uncovered path that is reachable in real use, fails in a way someone notices, and whose symptom
  you can state. Never an inventory of uncovered branches

When a test is genuinely missing, report it once, naming the defect and where the test belongs — not
one finding per uncovered function.


Before you accept a test as evidence, ask where its expected value comes from. Two sources make a test
green by construction, and both hide inside tests that look thorough:

- a stub, fake or stand-in that reimplements a production rule. Read the production rule it stands for
  and compare: a fake that accepts what production rejects, or orders what production leaves unordered,
  turns every test over it into a test of the fake. Name the production rule and the line of the fake
  that differs from it
- an expected value that comes from the same helper, allocator, table or code path as the value under
  test, including a historical constant copied from one earlier run of that path. The assertion then
  compares a thing with itself. Name the independent source the expected value should come from
