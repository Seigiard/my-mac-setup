---
name: tdd-integration
description: Enforce Test-Driven Development with strict Red-Green-Refactor cycle. Auto-triggers when implementing new features or functionality. Trigger phrases include "implement", "add feature", "build", "create functionality", or any request to add new behavior. Does NOT trigger for bug fixes, documentation, or configuration changes.
---

# TDD Integration Testing

Enforce strict Test-Driven Development using the Red-Green-Refactor cycle with dedicated subagents.

## Mandatory Workflow

Every new feature MUST follow this strict 3-phase cycle. Do NOT skip phases.

### Phase 1: RED - Write Failing Test

🔴 RED PHASE: Delegating to tdd-test-writer...

Invoke the `tdd-test-writer` subagent with:

- Feature requirement from user request
- Expected behavior to test

The subagent returns:

- Test file path
- Failure output confirming test fails
- Summary of what the test verifies

**Verify RED**: Confirm the test fails for the RIGHT reason — missing implementation, not syntax errors or import issues. If it fails for the wrong reason, fix the test and re-run.

**Do NOT proceed to Green phase until test failure is confirmed.**

#### RED Checkpoint

Use AskUserQuestion to present the failing test and ask:

```
RED phase complete. Test fails as expected.

Test file: [path]
Failure reason: [summary]

1. Approve — proceed to GREEN phase
2. Adjust tests — tell me what to change
```

Wait for user approval before proceeding.

### Phase 2: GREEN - Make It Pass

🟢 GREEN PHASE: Delegating to tdd-implementer...

Invoke the `tdd-implementer` subagent with:

- Test file path from RED phase
- Feature requirement context

The subagent returns:

- Files modified
- Success output confirming test passes
- Implementation summary

**Verify GREEN**: Run the full test suite — confirm all tests pass, including pre-existing tests. If any pre-existing test broke, fix the implementation without modifying existing tests.

**Do NOT proceed to Refactor phase until all tests pass.**

#### GREEN Checkpoint

Use AskUserQuestion to present the implementation and ask:

```
GREEN phase complete. All tests passing.

Files modified: [list]
Test results: [pass count]

1. Approve — proceed to REFACTOR phase
2. Adjust implementation — tell me what to change
```

Wait for user approval before proceeding.

### Phase 3: REFACTOR - Improve

🔵 REFACTOR PHASE: Delegating to tdd-refactorer...

Invoke the `tdd-refactorer` subagent with:

- Test file path
- Implementation files from GREEN phase

The subagent returns either:

- Changes made + test success output, OR
- "No refactoring needed" with reasoning

**Cycle complete when refactor phase returns.**

## Multiple Features

Complete the full cycle for EACH feature before starting the next:

Feature 1: 🔴 → 🟢 → 🔵 ✓
Feature 2: 🔴 → 🟢 → 🔵 ✓
Feature 3: 🔴 → 🟢 → 🔵 ✓

## Phase Violations

Never:

- Write implementation before the test
- Proceed to Green without seeing Red fail
- Proceed to Green without user approval at checkpoint
- Skip Refactor evaluation
- Start a new feature before completing the current cycle
