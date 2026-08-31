---
name: vector-prime
description: Read and write the Membrane workstreams dashboard (vector-prime) through its REST API — workstreams, weekly updates, metrics. Use when the user asks to post or edit a workstream update, change a north star or current focus, record a metric value, restore a deleted workstream, or read what a workstream is working on.
---

# Vector Prime

The Membrane Dashboard at <https://vector.membranehq.com> — a tree of **workstreams**, each carrying a north star, a current focus, dated **updates**, and **metrics**. The API is documented at `/api-docs`; this skill carries what that page states wrongly, plus the traps that make a write look like it worked when it did not.

## Every call goes through the helper

```bash
bash ~/.claude/skills/vector-prime/scripts/vp.sh <METHOD> <PATH> [JSON_BODY]
```

It supplies the base URL and the bearer token, prints the response body on 2xx, and exits 1 with the status on anything else. Pipe it into `jq` — responses are JSON.

```bash
bash ~/.claude/skills/vector-prime/scripts/vp.sh GET /workstreams | jq -r '.[] | "\(.id)  \(.name)"'
```

**Every method needs the token, GET included.** The `/api-docs` page says read endpoints work unauthenticated; that holds only inside the browser, where a session cookie stands in. Auth lives in one Next.js middleware that never looks at the HTTP method, so an unauthenticated `GET /api/workstreams` answers `401 {"error":"Unauthorized"}`. An invalid token gives the same generic 401 — there is no distinct message for a bad token.

The token comes from `VECTOR_PRIME_API_KEY`, exported by `.zshenv` from 1Password; the helper falls back to `op read` when the variable is unset. Against a local dashboard set `VECTOR_PRIME_API_URL=http://localhost:3456/api` — the app listens on **3456**, not 3000.

## Start from the workstream id

Every path takes a UUID and nothing accepts a name. Resolve what the user said against `GET /workstreams` first, and ask them which one when two names are close.

## Endpoints

| Method + path | Body / query | Returns |
|---|---|---|
| `GET /workstreams` | — | full tree, each node with `children` |
| `POST /workstreams` | `name` required; `type`, `icon`, `slack_channel`, `dri_name`, `dri_email`, `notion_url`, `parent_workstream_id`, `linear_label`, `north_star`, `current_focus`, `sort_order` optional | `{ id }` |
| `GET /workstreams/:id` | — | one workstream with `children` and `parent` |
| `PATCH /workstreams/:id` | any of the POST fields plus `linear_task_label_id`, `linear_project_label_id`, `linear_tasks_view_slug`, `linear_projects_view_slug` | `{ ok }` |
| `DELETE /workstreams/:id` | — | `{ ok }`, children re-parented to root |
| `GET /workstreams/:id/history` | — | Dolt commits with `changes` and `snapshot` |
| `GET /workstreams/deleted` | — | `{ id, name, icon, deleted_at }` recoverable from Dolt history |
| `POST /workstreams/deleted` | `id` | `{ ok, name }` — restores it |
| `GET /workstreams/:id/updates` | — | **newest first, capped at 20**, no paging |
| `POST /workstreams/:id/updates` | `date` required, `content` optional | `{ id }` |
| `PATCH /updates/:updateId` | `content` **required in practice**, `date` | `{ ok }` |
| `DELETE /updates/:updateId` | — | `{ ok }` |
| `GET /workstreams/:id/metrics` | — | metrics, each with **every value ever recorded** in `values` |
| `POST /workstreams/:id/metrics` | `name` required, `unit`, `description` | `{ id }` |
| `DELETE /workstreams/:id/metrics` | `date` | `{ ok }` — see the warning below |
| `PATCH /metrics/:metricId` | `name`, `unit`, `description`, `sort_order` | `{ ok }` |
| `DELETE /metrics/:metricId` | — | `{ ok }`, cascades to every value |
| `GET /metrics/:metricId/values` | `?from=&to=` inclusive | `[{ recorded_at, value, note }]` |
| `POST /metrics/:metricId/values` | `date`, `value` required, `note` | `{ ok }` — upsert on the date |
| `DELETE /metrics/:metricId/values` | `date` | `{ ok }` |
| `GET /workstreams/linear-focus` | `?label=` required, `tasksView`, `projectsView` | `{ issues, projects }` from Linear |
| `GET /slack/channel-info` | `?id=C01234ABCDE` | `{ id, name }` |
| `GET /tokens` | `?email=` | `{ token, created_at }` |
| `POST /tokens` | `email`, `name` | `{ token }` — revokes the old one first |
| `DELETE /tokens` | `email` | `{ ok }` |

`DELETE /workstreams/:id/metrics` appears in no documentation and reads like "delete a metric". It deletes **every metric value on the given date across every metric of the workstream**, and answers `{ ok }` whether it matched anything or not. To remove one number use `DELETE /metrics/:metricId/values`.

## Writes that leave the dashboard

Three write paths reach outside the database. Tell the user what will happen and get their go-ahead before running any of them.

- **Posting or editing an update posts to Slack** when the workstream has `slack_channel` set. `POST /workstreams/:id/updates` sends a message; `PATCH /updates/:updateId` edits the message already sent, or sends a first one when none exists. There is no dry-run and no suppression flag — read `slack_channel` off the workstream first. A Slack failure does not fail the request: the 2xx body carries an extra `slackError` string, so check for that field instead of trusting the status.
- **Setting `linear_label` creates or renames Linear labels**, on both create and update. A rename hits every Linear issue already carrying that label, org-wide. A Linear failure returns 500 and aborts the whole write.
- **`POST /tokens` revokes the named person's current token** before issuing a new one, which breaks whatever they had it wired into. `GET /tokens?email=` returns anyone's token in plaintext — read another person's only when they asked you to.

Deleting an update leaves its Slack message in the channel. Remove that by hand.

## Formats

- **Content fields hold HTML, not markdown.** `north_star`, `current_focus`, and update `content` are stored verbatim and rendered as HTML. Write `<p>`, `<strong>`, and `<ul><li><p>…</p></li></ul>`; markdown `**bold**` renders as literal asterisks, and plain text renders as one unwrapped run. Read an existing update before writing the first one, to match the house structure. Slack gets a converted version that understands `<strong>`, `<em>`, `<s>`, `<code>`, `<a href>`, `<li>`, and `<p>` — a tag outside that set is stripped to its text.
- **Dates are `YYYY-MM-DD`.** Both columns are 10-character strings and range filters compare them as strings, so zero-padding is what makes `from`/`to` work. An ISO timestamp does not fit.
- **One update per workstream per date.** `POST` answers `409` when the date is taken. Read `GET /workstreams/:id/updates`, take the `id` for that date, and `PATCH /updates/:updateId`.
- **Metric values upsert.** Re-posting a date overwrites both `value` and `note`.
- **Hierarchy is two levels deep.** The parent must exist and must itself be a root; a workstream with children cannot become a child; a workstream cannot be its own parent. Each violation is a `400` naming the rule.

## Traps that answer with the wrong status

- **A misspelled field name in a PATCH returns `404 {"error":"not found"}`** on a workstream or metric that exists. The route drops keys outside its allow-list, and a body left with nothing to write is reported as a missing record. On a 404 from PATCH, check the field names before concluding the id is wrong.
- **`PATCH /updates/:updateId` without `content` returns a raw 500**, not the usual `{error}` JSON — the undefined value reaches the database driver. Always send `content`, and send the full text: the field is replaced, not merged.
- **A metric value is coerced with `Number()`.** `""` becomes `0` and is written; a non-numeric string becomes `NaN` and produces a raw 500.
- **Posting a value to a nonexistent `metricId` answers `{ ok }`** and writes an orphan row. Confirm the metric id from `GET /workstreams/:id/metrics` rather than trusting the 200.
- **`GET /slack/channel-info` answers 200 for an unknown channel**, with `name: null` and an `error` field in the body.
- Every hand-written failure uses `{"error": "…"}`. A body that is not JSON means an unhandled database error, and the write may or may not have landed — re-read before retrying.

## What survives a delete

Workstreams live in Dolt and every mutation makes a commit, so `DELETE /workstreams/:id` is reversible: `GET /workstreams/deleted` lists what went, `POST /workstreams/deleted` restores it by id, and `GET /workstreams/:id/history` shows who changed what. Restoring an id that is already live gives a raw 500.

That safety net does not cover the rest. Deleting a workstream orphans its updates and metrics instead of removing them, and a deleted update or metric has no restore endpoint.

## Author attribution

The update author is read from the browser session cookie alone. An update written with a token posts to Slack with no "Posted by" line, and no field sets it. When attribution matters, tell the user to post that one from the dashboard.
