---
name: work-summary
description: Summarize the user's completed Linear issues for a period as a Slack update (default) or a themed report with ticket IDs, and write the next period's focus statement. Use when the user asks to summarize what they got done, wants a workstream or product update, asks to set or reword a period's focus, or asks in Russian ("кратко что я сделал", "сделай саммари моей работы", "сделай фокус на неделю").
---

# Work Summary

Summarize the user's completed Linear issues for a date range, in one of two output formats — and write the focus statement the next period will be measured against.

## Workflow

### 1. Resolve the date range

- Convert relative ranges ("last week") to absolute dates.
- Ask **only** when the period is genuinely unresolvable: no period stated at all, or an outright contradiction (e.g. "last week (12-17 jun)" when today is July).
- If the period is clear — "last week", explicit dates, "this month" — resolve it and proceed. **Do not re-confirm, do not ask for approval.** State the resolved range in the output and move on.

### 2. Fetch completed issues

`linear` is not on PATH. Use `bunx @schpet/linear-cli` — **not `npx`**: repo hooks in the Membrane platform checkout ban `npx` outright and the call fails before it runs. Query completed issues assigned to the user via GraphQL:

```bash
bunx @schpet/linear-cli api --variables-json '{"filter": {"assignee": {"isMe": {"eq": true}}, "completedAt": {"gte": "<START>T00:00:00Z", "lte": "<END>T23:59:59Z"}}}' <<'GRAPHQL' 2>/dev/null | grep -o '{"data".*' | jq '.data.issues.nodes'
query($filter: IssueFilter!) {
  issues(filter: $filter, first: 100) {
    nodes { identifier title completedAt project { name } state { name } description }
  }
}
GRAPHQL
```

The runner prints an install warning on first run that breaks `jq` — the `grep -o '{"data".*'` pipe strips it. Output can be large; if persisted to a file, extract per-issue title + first description lines with `jq` rather than reading raw.

If exactly 100 nodes return, the window overflowed the page — narrow the range or page with `after`. Window boundaries are UTC: an issue closed late Friday local time may land in Saturday.

### 3. Establish the period's focus

**Read it before asking for it.** The focus lives on the user's workstream in vector-prime, the Membrane workstreams dashboard — the `current_focus` field, alongside the `north_star` and the `slack_channel` the update gets posted to. Load the `vector-prime` skill for the API, or read it directly:

```bash
bash ~/.claude/skills/vector-prime/scripts/vp.sh GET /workstreams | jq -r '.. | objects | select(.name) | "\(.id)\t\(.name)\t\(.dri_name // "-")"'
bash ~/.claude/skills/vector-prime/scripts/vp.sh GET /workstreams/<id> | jq -r '.current_focus, .north_star, .slack_channel'
```

The field holds HTML, and it holds **two things at once**: a standing goal that outlives the period, and a "this week is focused on…" sentence that does not. Only the second one is this period's focus. Reading it also gives the house structure to match and tells you whether posting will hit Slack.

Then, in order:

- If the user pasted a focus, use it — it wins over the dashboard.
- If the dashboard's focus is present and still describes the period you are summarizing, use it and **say which focus you used in one line outside the artifact**, so a stale field is caught by the user rather than shipped.
- If it is absent, or clearly describes an earlier period, ask the user for the focus of this one. One question, then proceed.
- Skip this step only when the user asked for the flat shape or said the period had no focus.

The focus changes the output shape: with a focus, the update is anchored on it (default); without one, it is a flat list of accomplishments.

### 4. Fetch open issues (focus-anchored output only)

"Still ahead" must come from Linear state, never from re-reading the focus prose:

```bash
bunx @schpet/linear-cli api --variables-json '{"filter": {"assignee": {"isMe": {"eq": true}}, "state": {"type": {"nin": ["completed", "canceled"]}}}}' <<'GRAPHQL' 2>/dev/null | grep -o '{"data".*' | jq -r '.data.issues.nodes[] | "\(.identifier) | \(.state.name) | \(.title)"'
query($filter: IssueFilter!) {
  issues(filter: $filter, first: 100) {
    nodes { identifier title state { name } }
  }
}
GRAPHQL
```

**When the focus text names a problem that appears in neither list, search before claiming it is untracked** — it was probably closed just outside the window:

```bash
bunx @schpet/linear-cli api --variables-json '{"q": "<keyword>"}' <<'GRAPHQL' 2>/dev/null | grep -o '{"data".*' | jq -r '.data.searchIssues.nodes[] | "\(.identifier) | \(.state.name) | \(.completedAt // "-") | \(.assignee.name // "unassigned") | \(.title)"'
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

- **update** — the Slack workstream update, ready to paste, no ticket IDs. **This is the default.** Follow `references/update-format.md`, which has two shapes: focus-anchored (default when step 3 found a focus) and flat (no focus). Triggers: "update", "post", "#product", "report for the team", "summary", "кратко", "для саммари", "для отчёта", "отчёт".
- **report** — themed breakdown for the user's own consumption: each group gets a heading, a 1-3 sentence summary, and its issue list (`FRT-XXXX — title`), ending with a one-line TLDR. Follow `references/report-format.md`. Use it when the user wants ticket-level detail: "breakdown", "with ticket IDs", "по тикетам", "с айдишниками", "сгруппированный список тасков", 1:1 or perf-review prep. **Neither "report" nor Russian "отчёт" selects this format on its own** — both read like it and neither is it; the default stays the update, and only an explicit ask for ticket-level detail switches.

When the request does not make the choice obvious, produce the **update**.

## Writing the period's focus

A separate job from summarizing, and often the tail of the same conversation: the user pastes a Slack thread, a customer situation, or a goal and asks for the coming period's focus. See `references/focus-format.md` for the shape, the variants rule, and how a focus change propagates into the next update.

## Rules that apply to every output

- **Every artifact is written in English.** Updates, reports, focus statements, and anything else meant to be pasted somewhere are English regardless of the language the user asked in — the team's reports are English. Match the user's language only in the conversation around the artifact: your commentary, questions, and explanations. A Russian request never means a Russian deliverable.
- **Zero context.** Write for a reader who has not seen the focus document, the tickets, or this session. Never reference the focus text's own structure — no "area 1", no "the second theme", no numbering. Name each theme in words at the point of use: "On the carrier seeing what they pay for:".
- **The artifact never mentions the act of reporting.** No "as I said last week", no "I won't repeat myself", no "more detail in the previous update", no note that a section is deliberately short. The reader does not know what you told them before and does not care how the text was produced. When the user says "mention it briefly, no detail needed", that means fewer words about the thing itself — not a sentence announcing brevity.
- **A narrower scope changes the sections' content, never their shape.** "Only these two themes", "drop the epics", "just the fixes" all cut what goes inside the format; they do not license inventing headings or abandoning the focus-anchored shape. If the cut leaves a section empty, drop that section and keep the rest intact.
- **Never restore what the user deleted.** When the user edits a draft and hands it back, every removal is a decision. Reassembling a "final" text does not license putting a cut sentence back; if the removal looks wrong, say so and leave the text as they cut it.
- **State what is verified.** A range query proves what closed inside the window and nothing else. Before saying an item is untracked or unfixed, run the keyword search from step 4.
