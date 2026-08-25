---
name: se-simplify
description: Simplify changed code through fresh Claude Sonnet/high and OpenCode Terra/high reviews, then apply the synthesized behavior-preserving findings once. Use for a tidy or refactor pass before review.
argument-hint: "[scope description]"
---

# Cross-model simplify in herdr

Launch two fresh peer sessions to inspect the same simplification scope:

- Claude Code: Sonnet, effort `high`
- OpenCode: `openai/gpt-5.6-terra`, variant `high`

Each peer uses the `ce-simplify-code` rubric to produce findings without editing. After collecting both reports, close both panes before synthesis. The parent applies the accepted set exactly once and verifies behavior.

## Resolve scope

Resolve the scope using `ce-simplify-code` Step 1:

1. Use an explicitly named file, directory, function, or change range without widening it.
2. Otherwise use the current branch diff against its base branch.
3. If no base is available, use staged and unstaged changes against `HEAD`.
4. If no non-empty scope can be resolved, ask what to simplify and stop.

Capture the pre-apply worktree state so simplify-owned edits can be distinguished from existing user changes.

## Launch exactly two fresh peers

Require `HERDR_ENV=1`, `herdr`, `claude`, and `opencode`. There is no headless fallback. Use unique run-scoped agent names no longer than 32 characters.

Create sibling panes rooted at the repository without taking focus:

```bash
CLAUDE_PANE=$(herdr pane split --current --direction right --cwd "$REPO_ROOT" --no-focus \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')

OPENCODE_PANE=$(herdr pane split "$CLAUDE_PANE" --direction down --cwd "$REPO_ROOT" --no-focus \
  --env 'OPENCODE_CONFIG_CONTENT={"permission":"allow","agent":{"build":{"permission":"allow"}}}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
```

Start Claude exactly as:

```bash
herdr agent start "$CLAUDE_NAME" \
  --kind claude \
  --pane "$CLAUDE_PANE" \
  --timeout 60000 \
  -- \
  --model sonnet \
  --effort high \
  --dangerously-skip-permissions
```

Start OpenCode exactly as:

```bash
herdr agent start "$OPENCODE_NAME" \
  --kind opencode \
  --pane "$OPENCODE_PANE" \
  --timeout 60000 \
  -- \
  --model openai/gpt-5.6-terra \
  --variant high \
  --agent build \
  --auto
```

Do not substitute another model, effort, variant, agent, permission posture, launcher, or reused session.

## Prompt both before waiting

Send Claude this prompt:

```text
Invoke `/compound-engineering:ce-simplify-code` as the governing rubric for this scope:

<resolved scope>

Execute only Step 1 and Step 2: resolve the scope and run the code-reuse,
code-quality, and efficiency reviewers. Do not execute Steps 3 through 5.

This is an independent report-only simplification review. Do not edit files,
stage changes, commit, push, switch branches, or ask interactive questions.

Return structured findings with the reviewer dimension, file and location,
proposed behavior-preserving change, evidence, confidence, and required checks.
```

Send OpenCode this prompt:

```text
Use the `ce-simplify-code` skill as the governing rubric for this scope:

<resolved scope>

Execute only Step 1 and Step 2: resolve the scope and run the code-reuse,
code-quality, and efficiency reviewers. Do not execute Steps 3 through 5.

This is an independent report-only simplification review. Do not edit files,
stage changes, commit, push, switch branches, or ask interactive questions.

Return structured findings with the reviewer dimension, file and location,
proposed behavior-preserving change, evidence, confidence, and required checks.
```

Submit both prompts without `--wait`, then wait for each agent:

```bash
herdr agent prompt "$CLAUDE_NAME" "$CLAUDE_PROMPT"
herdr agent prompt "$OPENCODE_NAME" "$OPENCODE_PROMPT"
herdr agent wait "$CLAUDE_NAME" --timeout 1800000
herdr agent wait "$OPENCODE_NAME" --timeout 1800000
```

Read Claude from `visible` and OpenCode from `recent-unwrapped`:

```bash
CLAUDE_REPORT=$(herdr agent read "$CLAUDE_NAME" --source visible --format text)
OPENCODE_REPORT=$(herdr agent read "$OPENCODE_NAME" --source recent-unwrapped --format text)
```

Require a complete report, not only a settled process state. One failed peer degrades coverage; two failed peers fail the simplify run and apply nothing.

## Close peers before synthesis

After reading the available reports, close both panes created by this run:

```bash
herdr pane close "$CLAUDE_PANE"
herdr pane close "$OPENCODE_PANE"
```

Close them on success, failure, malformed output, or timeout. Never resume or reuse an agent from another phase.

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
