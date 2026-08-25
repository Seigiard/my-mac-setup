---
name: se-code-review
description: Review code through two fresh cross-model peer sessions, synthesize both reports, and apply clear verified fixes. Use before a PR or when asked to review code.
argument-hint: "[mode:agent] [PR URL/number | branch | base:<ref>] [plan:<path>] [depth:auto|full] [grouping:auto|off|always]"
---

# Cross-model code review in herdr

Run the same `compound-engineering:ce-code-review` workflow through two fresh peer sessions.

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

## Dispatch fresh peers

Read `~/.claude/shared/herdr-peer-launch.md` in full. It is the single source of truth for pane creation, exact models and permissions, concurrent dispatch, wait and read behavior, and close-before-synthesis cleanup.

Set `REPO_ROOT` to the current checkout. Supply the following dispatch briefs as the reference's `CLAUDE_PROMPT` and `OPENCODE_PROMPT` inputs.

### Claude prompt

Send Claude this prompt:

```text
Invoke `/compound-engineering:ce-code-review` with these exact arguments:

mode:agent <resolved arguments>

This is an independent report-only review. Do not edit files, stage changes,
commit, push, switch branches, or ask interactive questions.

Run the complete reviewer selection, persona dispatch, validation, merge, and
JSON output flow. Return the final raw JSON report.
```

### OpenCode prompt

```text
Use the `ce-code-review` skill with these exact arguments:

mode:agent <resolved arguments>

This is an independent report-only review. Do not edit files, stage changes,
commit, push, switch branches, or ask interactive questions.

Run the complete reviewer selection, persona dispatch, validation, merge, and
JSON output flow. Return the final raw JSON report.
```

Execute the shared lifecycle through pane closure. Require a complete parseable JSON report from each peer. One failed or malformed peer degrades coverage; two failed peers fail the review. Do not pass peer context into `se-simplify`.

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
