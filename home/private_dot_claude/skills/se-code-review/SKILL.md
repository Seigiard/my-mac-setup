---
name: se-code-review
description: Review code through fresh Claude Sonnet/high and OpenCode Terra/high sessions, synthesize both reports, and apply clear verified fixes. Use before a PR or when asked to review code.
argument-hint: "[mode:agent] [PR URL/number | branch | base:<ref>] [plan:<path>] [depth:auto|full] [grouping:auto|off|always]"
---

# Cross-model code review in herdr

Run the same `compound-engineering:ce-code-review` workflow through two fresh peer sessions:

- Claude Code: Sonnet, effort `high`
- OpenCode: `openai/gpt-5.6-terra`, variant `high`

Both peers review the same current checkout independently in `mode:agent`. They return reports and never edit the checkout. After collecting their reports, close both panes before synthesis. Never resume or reuse either peer, and never retain one for another phase.

## Resolve arguments

Parse arguments according to `ce-code-review`:

- Always pass `mode:agent` to both peers. It is the supported report-only JSON mode and skips the plugin's apply stage.
- Forward `base:`, `plan:`, `depth:`, and `grouping:` unchanged.
- Forward an optional PR URL, PR number, or branch target.
- Reject `base:` combined with a PR or branch target.
- Normalize `mode:headless` to `mode:agent`.
- Remove `mode:report-only` and `mode:autofix`; both are deprecated or ignored and do not create a report-only run.

Empty target arguments review the current branch against its detected base. Record whether the worktree is clean before review; the apply stage uses that fact.

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

Start Claude with the exact model, effort, and permission bypass:

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

Start OpenCode with the exact model, variant, build agent, and permission bypass:

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
Invoke `/compound-engineering:ce-code-review` with these exact arguments:

mode:agent <resolved arguments>

This is an independent report-only review. Do not edit files, stage changes,
commit, push, switch branches, or ask interactive questions.

Run the complete reviewer selection, persona dispatch, validation, merge, and
JSON output flow. Return the final raw JSON report.
```

Send OpenCode this prompt:

```text
Use the `ce-code-review` skill with these exact arguments:

mode:agent <resolved arguments>

This is an independent report-only review. Do not edit files, stage changes,
commit, push, switch branches, or ask interactive questions.

Run the complete reviewer selection, persona dispatch, validation, merge, and
JSON output flow. Return the final raw JSON report.
```

Submit both prompts without `--wait`, then wait for each agent. This starts both reviews before either wait can block:

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

A settled state is only a wake-up signal: require a complete parseable JSON report. One failed or malformed peer degrades coverage; two failed peers fail the review.

## Close peers before synthesis

After reading the available reports, close both panes created by this run:

```bash
herdr pane close "$CLAUDE_PANE"
herdr pane close "$OPENCODE_PANE"
```

Close them on success, failure, malformed output, or timeout. Do not continue either session and do not pass any peer context into `se-simplify`.

## Synthesize reports

Merge findings by file, nearby line, and issue substance:

1. **Consensus**: both reports found the same issue.
2. **Claude-only**: only Sonnet found it.
3. **OpenCode-only**: only Terra found it.
4. **Contradiction**: the reports disagree on whether the issue exists or what behavior is correct.
5. **Fix divergence**: they agree on the issue but propose materially different fixes.

Keep the highest supported severity. Treat cross-model agreement as stronger evidence, not proof. Use the most conservative supported verdict unless it depends only on a finding rejected during synthesis.

## Apply findings in default mode

Skip apply when this wrapper was invoked with `mode:agent`; return the synthesized machine handoff instead.

In default mode, the parent is the only apply owner. Mirror `ce-code-review` Stage 5c:

- Apply every merged finding that is a clear improvement and reversible edit, regardless of severity.
- Judge consensus and unique findings on their merits. A unique source is not a deny condition.
- Treat `autofix_class` as routing signal, not apply permission. Do not mechanically apply every `gated_auto` finding.
- Do not apply contradictions, design decisions, taste calls, advisory findings, or findings the parent determines are wrong.
- Apply only when the current working tree is the tree that both peers reviewed.
- Run targeted tests and lint after each coherent fix group. Broaden checks when the change touches shared behavior.
- Revert a fix that makes verification fail; never leave the tree red.
- Self-review the complete apply delta and rerun affected checks after follow-up edits.
- Never push, open a PR, or file tickets.

If the pre-review tree was clean, commit verified fixes as one review-labeled commit following repository conventions. If it was dirty, leave fixes uncommitted and list every file changed by the apply stage.

## Output

Report peer coverage, merged verdict, consensus, source-unique findings, contradictions, fixes applied or skipped, verification commands and results, commit status, and remaining actionable findings. In `mode:agent`, return one JSON object and no prose outside it.
