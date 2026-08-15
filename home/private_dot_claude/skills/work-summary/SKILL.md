---
name: work-summary
description: Summarize the user's completed Linear issues for a period as a Slack update (default) or a themed report with ticket IDs. Use when the user asks to summarize what they got done, wants a workstream or product update, or asks in Russian ("кратко что я сделал", "сделай саммари моей работы").
---

# Work Summary

Summarize the user's completed Linear issues for a date range, in one of two output formats.

## Workflow

### 1. Resolve the date range

- Convert relative ranges ("last week") to absolute dates.
- Ask **only** when the period is genuinely unresolvable: no period stated at all, or an outright contradiction (e.g. "last week (12-17 jun)" when today is July).
- If the period is clear — "last week", explicit dates, "this month" — resolve it and proceed. **Do not re-confirm, do not ask for approval.** State the resolved range in the output and move on.

### 2. Fetch completed issues

`linear` is not on PATH — use `npx @schpet/linear-cli`. Query completed issues assigned to the user via GraphQL:

```bash
npx @schpet/linear-cli api --variables-json '{"filter": {"assignee": {"isMe": {"eq": true}}, "completedAt": {"gte": "<START>T00:00:00Z", "lte": "<END>T23:59:59Z"}}}' <<'GRAPHQL' 2>/dev/null | grep -o '{"data".*' | jq '.data.issues.nodes'
query($filter: IssueFilter!) {
  issues(filter: $filter, first: 100) {
    nodes { identifier title completedAt project { name } state { name } description }
  }
}
GRAPHQL
```

`npx` prints an install warning on first run that breaks `jq` — the `grep -o '{"data".*'` pipe strips it. Output can be large; if persisted to a file, extract per-issue title + first description lines with `jq` rather than reading raw.

If exactly 100 nodes return, the window overflowed the page — narrow the range or page with `after`. Window boundaries are UTC: an issue closed late Friday local time may land in Saturday.

### 3. Establish the period's focus

If the user pasted a focus, use it. If they asked for the flat shape or said the period had no focus, skip this step. Otherwise ask for the focus they stated at the start of the period. Most periods have one — a written focus statement, a weekly goal, an epic.

The focus changes the output shape: with a focus, the update is anchored on it (default); without one, it is a flat list of accomplishments.

### 4. Fetch open issues (focus-anchored output only)

"Still ahead" must come from Linear state, never from re-reading the focus prose:

```bash
npx @schpet/linear-cli api --variables-json '{"filter": {"assignee": {"isMe": {"eq": true}}, "state": {"type": {"nin": ["completed", "canceled"]}}}}' <<'GRAPHQL' 2>/dev/null | grep -o '{"data".*' | jq -r '.data.issues.nodes[] | "\(.identifier) | \(.state.name) | \(.title)"'
query($filter: IssueFilter!) {
  issues(filter: $filter, first: 100) {
    nodes { identifier title state { name } }
  }
}
GRAPHQL
```

**When the focus text names a problem that appears in neither list, search before claiming it is untracked** — it was probably closed just outside the window:

```bash
npx @schpet/linear-cli api --variables-json '{"q": "<keyword>"}' <<'GRAPHQL' 2>/dev/null | grep -o '{"data".*' | jq -r '.data.searchIssues.nodes[] | "\(.identifier) | \(.state.name) | \(.completedAt // "-") | \(.assignee.name // "unassigned") | \(.title)"'
query($q: String!) {
  searchIssues(term: $q, first: 25) {
    nodes { identifier title state { name } completedAt assignee { name } }
  }
}
GRAPHQL
```

### 5. Group by theme

Group issues by outcome, not by ticket: a large migration and its fallout form one theme; scattered small fixes roll up into a named bucket ("CI stability", "auth reliability"). 4-6 themes max. Grouping is done when every issue the query returned sits in exactly one theme — an issue that fits nowhere means the theme set is wrong, not that the issue is dropped.

With a focus, the focus's own themes are the grouping — map each done issue onto the theme it serves, and put the rest in one "outside the focus" bucket.

### 6. Pick the output format

- **update** — the Slack #product workstream update, ready to paste, no ticket IDs. **This is the default.** Follow `references/update-format.md`, which has two shapes: focus-anchored (default when step 3 found a focus) and flat (no focus). Triggers: "update", "post", "#product", "report for the team", "summary", "кратко", "для саммари".
- **report** — themed breakdown for the user's own consumption: each group gets a heading, a 1-3 sentence summary, and its issue list (`FRT-XXXX — title`), ending with a one-line TLDR. Follow `references/report-format.md`. Use it when the user wants ticket-level detail: "breakdown", "with ticket IDs", "по тикетам", 1:1 or perf-review prep. The bare word "report" alone does NOT select this format — the default remains the update.

When the request does not make the choice obvious, produce the **update**.

## Rules that apply to every output

- **Zero context.** Write for a reader who has not seen the focus document, the tickets, or this session. Never reference the focus text's own structure — no "area 1", no "the second theme", no numbering. Name each theme in words at the point of use: "On the carrier seeing what they pay for:".
- **Never restore what the user deleted.** When the user edits a draft and hands it back, every removal is a decision. Reassembling a "final" text does not license putting a cut sentence back; if the removal looks wrong, say so and leave the text as they cut it.
- **State what is verified.** A range query proves what closed inside the window and nothing else. Before saying an item is untracked or unfixed, run the keyword search from step 4.
