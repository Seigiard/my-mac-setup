---
name: se-simplify
description: Simplify changed code through two fresh cross-model peer reviews, then apply the synthesized behavior-preserving findings once. Use for a tidy or refactor pass before review.
argument-hint: "[scope description]"
---

# Cross-model simplify in herdr

Launch two fresh peer sessions to inspect the same simplification scope.

Each peer uses the `ce-simplify-code` rubric to produce findings without editing. After collecting both reports, close both tabs before synthesis. The parent applies the accepted set exactly once and verifies behavior.

## Resolve scope

Resolve the scope using `ce-simplify-code` Step 1:

1. Use an explicitly named file, directory, function, or change range without widening it.
2. Otherwise use the current branch diff against its base branch.
3. If no base is available, use staged and unstaged changes against `HEAD`.
4. If no non-empty scope can be resolved, ask what to simplify and stop.

Capture the pre-apply worktree state so simplify-owned edits can be distinguished from existing user changes.

## Dispatch fresh peers

Read `~/.claude/shared/herdr-peer-launch.md` in full. It is the single source of truth for tab creation, exact models and permissions, concurrent dispatch, wait and read behavior, and close-before-synthesis cleanup.

Set `REPO_ROOT` to the current checkout. Supply the following dispatch briefs as the reference's `CLAUDE_PROMPT` and `OPENCODE_PROMPT` inputs.

### Claude prompt

Send Claude this prompt:

```text
Invoke `/compound-engineering:ce-simplify-code` as the governing rubric for this scope:

<resolved scope>

Execute only Step 1 and Step 2: resolve the scope and run the code-reuse,
code-quality, and efficiency reviewers. Do not execute Steps 3 through 5.

This is an independent report-only simplification review. Do not edit repository
files, stage changes, commit, push, switch branches, or ask interactive questions.
The shared lifecycle's report transport file is the only permitted write.

Return a complete report with these sections:
- Coverage: status for code-reuse, code-quality, and efficiency.
- Findings: reviewer dimension, file and location, proposed behavior-preserving
  change, evidence, confidence, and required checks for every accepted item.
- Rejected or uncertain: every candidate excluded as unsafe, contradictory,
  false-positive, or low-value, with its reason.
Write `Findings: none` when no item survives. End with the exact line:
Simplify review complete
```

### OpenCode prompt

```text
Use the `ce-simplify-code` skill as the governing rubric for this scope:

<resolved scope>

Execute only Step 1 and Step 2: resolve the scope and run the code-reuse,
code-quality, and efficiency reviewers. Do not execute Steps 3 through 5.

This is an independent report-only simplification review. Do not edit repository
files, stage changes, commit, push, switch branches, or ask interactive questions.
The shared lifecycle's report transport file is the only permitted write.

Return a complete report with these sections:
- Coverage: status for code-reuse, code-quality, and efficiency.
- Findings: reviewer dimension, file and location, proposed behavior-preserving
  change, evidence, confidence, and required checks for every accepted item.
- Rejected or uncertain: every candidate excluded as unsafe, contradictory,
  false-positive, or low-value, with its reason.
Write `Findings: none` when no item survives. End with the exact line:
Simplify review complete
```

Execute the shared lifecycle through tab closure. Accept a report only when Coverage accounts for all three reviewer dimensions, every surviving finding contains every required field, excluded candidates carry a reason, and the terminal line is exact. One failed or malformed peer degrades coverage; two failed peers fail the simplify run and apply nothing.

## Synthesize findings

Merge findings into consensus, Claude-only, OpenCode-only, contradictions, and behavior-preservation uncertainty.

- Accept defensible consensus and unique findings.
- Exclude contradictions, false positives, low-value churn, and proposals that cannot prove equivalent output, errors, side effects, or ordering.
- Never simplify away validation, authorization, escaping, sanitization, data-loss prevention, accessibility behavior, or other safety checks.
- Prefer readable explicit code over compact code. Fewer lines are not the goal.

## Apply once

The parent is the only apply owner. Apply each accepted finding directly, skipping any item that is no longer valid in the current code or cannot preserve behavior. Do not let either peer edit the checkout and do not create a second apply owner.

## Verify

After applying the synthesized simplifications, follow `ce-simplify-code` Step 4:

- Run the project's full typecheck and lint commands when available.
- Run tests scoped to the changed paths.
- Broaden tests when shared or widely imported code changed.
- Run the full suite when the test runner cannot scope execution.
- If a check fails, fix or revert the simplification that caused it.
- Never weaken tests, assertions, or types to obtain a passing result.

Resolve commands from repository instructions, a plan's Verification Contract, package scripts, Makefile targets, and existing CI configuration. Do not invent commands or require a separate caller-supplied verification argument.

Report every command run and its result. If no applicable verification command can be found, state that the simplification remains unverified.

## Output

Report peer coverage; consensus, unique findings, and contradictions; applied and skipped findings by reuse, quality, and efficiency; verification commands and results; and remaining risks. Do not commit or push unless the user explicitly requested it.
