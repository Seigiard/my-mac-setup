---
title: GitHub Issues Migration - Research
type: research
date: 2026-09-13
topic: github-issues-migration
status: complete
execution: none
---

# GitHub Issues Migration - Research

## What this document is

This note evaluates whether GitHub Issues should replace the validated Markdown
records under `docs/issues/`. It does not change the source of truth, migrate any
record, enable or disable a repository feature, or supersede ADR-0007.

The evidence boundary is deliberately narrow:

- **Repository facts** come from the current checkout, its issue CLI, and
  read-only queries against `Seigiard/my-mac-setup`.
- **GitHub facts** come from current first-party GitHub documentation, the
  current GitHub API schema, and GitHub CLI 2.100.0.
- **Recommendations and scores** are judgments derived from those facts, not
  claims made by GitHub.

## Decision outcome

After reviewing this evidence, the maintainer chose GitHub Issues as the sole
repository work tracker. ADR-0013 records the accepted decision and supersedes
ADR-0007. The executive conclusion below remains the research recommendation
that preceded that decision, not the repository's current policy.

## Executive conclusion

**Do not supersede ADR-0007 yet.** The local tracker remains the lower-risk
authority: it is validated, deterministic, available in every checkout, and
preserves its exact Git history. GitHub Issues offers materially better comments,
notifications, cross-linking, and browser visibility, but a public API migration
cannot preserve original issue numbers, native authors, creation and closure
timestamps, or the original event timeline.

The next justified step is a **reversible import pilot in a private scratch
repository**. If that pilot demonstrates an actual workflow benefit and passes
the parity and restart tests below, the preferred production strategy is to
import only the 37 active records and freeze all 59 Markdown records as an
immutable local archive. GitHub would then become the sole authority for active
work. Importing all 59 records is possible only as a representation of history,
not as native historical preservation. Permanent dual-write is not recommended.

## API availability and deprecation check

This check precedes the recommendation because a migration must not be designed
around a retiring API.

- The current REST issue, comment, label, sub-issue, and dependency pages use API
  version `2026-03-10` and carry no deprecation or sunset banner.
- GitHub's current GraphQL breaking-changes page does not identify the issue or
  Projects v2 operations used here as scheduled for removal. This is a point-in-
  time finding, not a guarantee against later schema changes.
- **Projects (classic) is deprecated and must not be used.** Any project work in
  a pilot must use Projects v2 through GraphQL or `gh project`.
- Issue forms are still marked public preview and subject to change. They are
  useful for later human intake, but the migration must not depend on them.
- The issue endpoints and live schema gained capabilities over time. An importer
  should pin an API version, inspect response schemas, and re-run this deprecation
  check immediately before execution.

Primary sources: [REST breaking changes](https://docs.github.com/en/rest/about-the-rest-api/breaking-changes),
[GraphQL breaking changes](https://docs.github.com/en/graphql/overview/breaking-changes),
[Projects (classic) sunset](https://github.blog/changelog/2024-05-23-sunset-notice-projects-classic),
and [issue-form syntax](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/syntax-for-issue-forms).

## Current repository baseline

### Local tracker

`python3 scripts/issues validate` succeeds over 59 canonical records:

| Local status | Count |
|---|---:|
| `open` | 37 |
| `in-progress` | 0 |
| `done` | 20 |
| `wontfix` | 2 |

The corpus uses all four types (`bug`, `follow-up`, `idea`, and `chore`), five
currently represented categories, three currently represented priorities, 83
unique free-form tags, six `parent-plan` values, and nine source records
containing 11 references to other issue records. No record currently has
`external-id`. The largest body is
8,506 bytes, the largest complete record is 9,074 bytes, and the maximum observed
tag count on one record is five. These are measured corpus properties, not claims
about GitHub's limits.

The local contract is stronger than a directory of prose. `scripts/issues`
validates a closed schema, deterministic queries, protected lifecycle edges,
status-specific body sections, atomic replacement, and a worktree-wide lock.
ADR-0007 makes those records authoritative; Git supplies exact edit history.

Repository sources: `docs/decisions/0007-use-validated-markdown-records-as-the-issue-tracker.md`,
`docs/agents/issue-tracker.md`, `docs/agents/triage-labels.md`,
`.opencode/skills/repository-issues/SKILL.md`, `scripts/issues`, and
`tests/test_issues.py`.

### Hosted repository state

Read-only checks on 2026-09-13 returned:

- `Seigiard/my-mac-setup` is **public** and user-owned.
- The maintainer enabled GitHub Issues; `hasIssuesEnabled` is **true**.
- Listing all GitHub issues returned an empty list.
- The repository has GitHub's nine ordinary default labels.
- The active `gh` token has `repo` but not `read:project` or `project`; a Projects
  pilot would require an explicit scope grant.

Recheck the feature setting before any pilot or cutover; do not assume that an
empty issue list or repository setting remains stable.

## Recommended capability mapping

The mapping below targets this repository as it exists now: a **user-owned**
repository. GitHub documents issue types as organization-level configuration and
documents issue fields as unavailable to user-owned repositories. Consequently,
neither is a dependable native home for the local schema here.

| Local contract | Recommended GitHub representation | Fidelity |
|---|---|---|
| Canonical filename ID | Stable body provenance marker plus migration manifest | Exact as imported text; GitHub assigns a different issue number |
| `title` | Issue title | Direct |
| `short_description` | `## Summary` at the start of the body | Direct text, not a separate native field |
| `type` | Namespaced label such as `type:bug` | Exact controlled value |
| `category` | Namespaced label such as `category:agent-platform` | Exact controlled value |
| `priority` | Namespaced label such as `priority:high` | Exact controlled value |
| Free-form `tags` | Namespaced labels such as `tag:testing` | Exact value without colliding with workflow labels |
| Triage role tags | Keep the canonical names `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix` | Direct and compatible with the existing skills vocabulary |
| `open` | Open GitHub issue | Direct |
| `in-progress` | Open issue plus reserved `status:in-progress` label | Explicit and queryable without Projects permission |
| `done` | Closed issue with reason `completed` | Direct lifecycle meaning; historical close time is not preserved |
| `wontfix` | Closed issue with reason `not_planned`, retaining `wontfix` when it is also the triage role | Direct lifecycle meaning; historical close time is not preserved |
| `date` and `closed` | Visible import provenance and machine-readable body marker | Original values preserved only as content |
| Active body sections | Issue body | Direct Markdown |
| `## Resolution` | Retain in body, then close with the mapped state reason | Content is exact; native close event is new |
| `parent-plan` | Body link to the plan and provenance manifest | A plan file is not a GitHub issue; do not invent a sub-issue relation |
| Issue-to-issue references | Rewrite in a second pass to include the assigned `#number`, retaining the original ID | Navigable after every target number is known |
| Git edit history | Frozen local archive and immutable commit permalink | Cannot become GitHub's native issue timeline |

The reserved namespaces prevent the local type `bug`, the triage category label
`bug`, and a free-form tag from silently collapsing into one GitHub label. A
pilot must verify the observed maximum of nine mapped labels per issue rather
than rely on an undocumented limit.

### Why Projects v2 is optional, not canonical

A user-owned Projects v2 board can represent `Todo`, `In Progress`, and `Done`
with a single-select Status field. GitHub provides built-in workflows that can
set Status to Done when an issue closes, and its GraphQL API can add an item then
update its field value. GitHub explicitly says those are separate mutations.

That board adds a second permissions and query surface: the current token lacks
the required `read:project`/`project` scope, and ordinary issue list filters do
not replace project-item queries. For the pilot, `status:in-progress` should be
canonical and a project should be evaluated only as a derived view. Promote
Projects v2 to the lifecycle contract only if its board value is demonstrated
and every supported agent can query and mutate it reliably.

Primary sources: [managing issue types](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/managing-issue-types-in-an-organization),
[REST issue fields and issue operations](https://docs.github.com/en/rest/issues/issues),
[Projects API](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects),
and [built-in project automations](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-built-in-automations).

## REST, GraphQL, and `gh` automation surface

| Capability | REST | GraphQL | GitHub CLI | Migration use |
|---|---|---|---|---|
| Create/read/update issues | First-class endpoints | `createIssue`, `updateIssue`, and `Issue` | `gh issue create/list/view/edit` | Prefer versioned REST through `gh api` for structured responses |
| Labels | Create/list/update labels and set issue labels | Label connections and add/remove mutations | `gh label`; `gh issue --label`/`--add-label` | Pre-create controlled labels; verify after every issue create |
| Close reason | `state` plus `state_reason` (`completed`, `not_planned`, `duplicate`, `reopened`) | Issue state update input | `gh issue close --reason` | Apply only after body and labels verify |
| Comments | List/create/update/delete comments | Comment connections and mutations | `gh issue comment`; `gh issue view --comments` | Do not manufacture comments from old body sections |
| Issue types | Read/write fields are present | Issue type fields and inputs are present | `--type` is present | Not usable as this user-owned repository's controlled type system |
| Projects v2 fields | Not the primary documented Projects v2 mutation surface | Add item and update field mutations | `gh project item-add/item-edit` | Optional derived board; requires project scopes |
| Sub-issues | Get/list/add/remove/reprioritize | Parent/sub-issue fields and mutations | `--parent`, `--add-sub-issue` | Use only for an explicit issue hierarchy, not `parent-plan` |
| Blocking dependencies | List/add/remove `blocked_by`; list `blocking` | Blocking fields and mutations | `--blocked-by`, `--blocking`, edit equivalents | Do not infer dependencies from ordinary textual links |
| Timeline/history | Events and timeline are readable | Timeline connections are readable | Readable in issue views/JSON fields | No public import/backdate operation was found |
| Pagination | `Link` headers; list endpoints generally accept up to 100/page | Cursor connections with `pageInfo` | `gh api --paginate`; issue commands have explicit limits | Fetch every page and exclude pull requests from REST issue results |

`gh issue list/view --json` in CLI 2.100.0 exposes, among other fields,
`author`, `blockedBy`, `blocking`, `comments`, `createdAt`, `closedAt`,
`issueType`, `parent`, `projectItems`, `stateReason`, and `subIssues`. `gh issue
create/edit` also exposes current type, project, parent, sub-issue, and dependency
flags. These make `gh` useful for operator inspection. The importer should still
use `gh api` with explicit JSON because it needs response IDs, pagination,
version headers, and restart-safe verification rather than human-oriented output.

Primary sources: [REST issues](https://docs.github.com/en/rest/issues/issues),
[comments](https://docs.github.com/en/rest/issues/comments),
[labels](https://docs.github.com/en/rest/issues/labels),
[sub-issues](https://docs.github.com/en/rest/issues/sub-issues),
[issue dependencies](https://docs.github.com/en/rest/issues/issue-dependencies),
[timeline](https://docs.github.com/en/rest/issues/timeline),
[GraphQL issues reference](https://docs.github.com/en/graphql/reference/issues),
[GraphQL pagination](https://docs.github.com/en/graphql/guides/using-pagination-in-the-graphql-api),
[REST pagination](https://docs.github.com/en/rest/using-the-rest-api/using-pagination-in-the-rest-api),
and [`gh api`](https://cli.github.com/manual/gh_api).

## Preservation limits

The central migration limitation is native history, not body format.

The documented REST create input accepts title, body, milestone, labels,
assignees, issue fields, type, and parent. The live GraphQL `CreateIssueInput`
similarly exposes repository, title, body, assignees, milestone, labels, projects,
template, issue type, parent, issue fields, and agent assignment. Neither input
offers a caller-selected issue number, author, `created_at`, `closed_at`, or event
timeline. Comment creation accepts a body, not an original author or timestamp.

Therefore:

- GitHub assigns new sequential issue numbers.
- The importing identity becomes the native issue and comment author.
- Native creation, update, comment, and close timestamps reflect the import.
- Closing a migrated terminal record creates a new close event.
- Events/timeline endpoints can read GitHub history but do not provide a public
  operation to insert old events.
- The local records do not contain a reliable reporter field. Git commit authors
  are evidence about edits, not automatically the issue's original reporter.
- Copying original dates and identities into the body preserves information but
  must be labeled as imported provenance, never presented as native metadata.

This is why “migrate all history” must not be described as lossless. The complete
Markdown and its Git history can remain lossless only in the frozen archive.

## Agent reliability and importer design

GitHub makes the tracker reachable from the browser and from any authenticated
agent, but it also introduces network, token, permissions, API-version, rate-
limit, and pagination failure modes that the local CLI does not have.

### One agent contract

Do not replace one deterministic local command with scattered raw `gh` recipes.
Keep one repository-owned wrapper that:

1. defines the label and state mapping;
2. emits stable JSON for list/show/create/start/close/wontfix operations;
3. validates exactly one lifecycle edge at a time;
4. follows every REST page and every GraphQL cursor;
5. filters pull requests out of REST issue results;
6. checks authentication and required scopes before mutation;
7. reads the issue back and compares title, body marker, labels, state, reason,
   and relations after every write; and
8. stops on missing, silently dropped, duplicated, or unexpected data.

GitHub documents that labels, assignees, milestones, issue fields, and types can
be silently dropped when the caller lacks the required access. A successful HTTP
status alone is therefore not sufficient verification.

### Restart-safe import manifest

Use the repository's existing reviewed-manifest pattern rather than a one-shot
shell loop. Each source entry should contain:

- source commit, canonical path, canonical ID, and source SHA-256;
- exact planned title, body SHA-256, labels, state, state reason, and relations;
- a unique body marker such as
  `<!-- migrated-from: docs/issues/<file>; source-sha256: <hash> -->`;
- target repository, issue number, node ID, URL, and returned body marker after
  creation; and
- per-phase state: `planned`, `created`, `verified`, `linked`, and `closed`.

On restart, trust neither a number range nor an eventually consistent search.
If a target number is recorded, fetch it directly and verify the marker. If it
is not recorded, page through all target issues, including closed issues, and
scan for the exact marker. Continue only when exactly zero or one match exists;
more than one is a terminal duplicate error. Persist the returned target ID
atomically before the next mutation.

Create every issue before rewriting issue references or adding explicit
relations. Then verify bodies and labels, apply relations, close terminal issues,
and perform a final full export comparison. Never automatically “repair” a
target whose marker exists but whose content differs; report the drift for human
review.

### Rate and error handling

GitHub documents a general authenticated REST limit of 5,000 requests per hour,
plus secondary limits. Content generation is generally limited to 80 requests
per minute and 500 per hour, with lower undisclosed limits possible. GitHub's
official best practices say to serialize requests, wait at least one second
between mutative requests, honor `retry-after` and `x-ratelimit-reset`, use
exponential backoff for repeated secondary limits, and stop after a bounded
number of retries.

Fifty-nine issues are comfortably below the documented primary limit, but the
import includes labels, verification reads, optional relations, and closures.
It should still use a serial queue, one-second mutation spacing, response-header
logging, and fail-closed retries. Do not retry `4xx` validation errors blindly.

Primary sources: [REST rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
and [REST best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api).

## Strategy evaluation

### 1. Import all 59 records

**Benefit:** One hosted search surface contains both active and terminal work;
old cross-references can become GitHub links.

**Cost:** Twenty-two terminal records become newly created and newly closed
issues, with importer authorship and 2026 import timestamps. Notifications and
the issue number sequence are noisy, and the resulting timeline visually implies
history that did not occur on GitHub. The local archive is still required for
truthful history, so this does not eliminate the archive.

**Verdict:** Acceptable only if hosted search of terminal work is a proven need
and every imported body visibly discloses the historical metadata mismatch.

### 2. Import 37 active records and freeze all 59 locally

**Benefit:** GitHub begins with work that can still change, while the immutable
archive preserves all original content and Git history. No synthetic close
events are created for completed work. Rollback starts from an untouched corpus.

**Cost:** Historical work remains in a second, read-only location. Links from an
active issue to one of the 22 terminal records must use immutable commit
permalinks. Search across current and historical work is not one native query.

**Verdict:** **Preferred migration strategy** if the pilot justifies migration.
The archive must be clearly marked non-authoritative for new work and protected
by a path-and-hash manifest so “immutable” is enforced, not aspirational.

### 3. Permanent mirror or dual-write

**Benefit:** Both offline Markdown and hosted workflows appear available, and
rollback looks easy before divergence begins.

**Cost:** GitHub comments, state changes, label edits, issue transfers, and
timestamps do not have a lossless inverse into the local schema. Simultaneous
writes require conflict resolution, event ordering, webhook delivery recovery,
identity mapping, and loop prevention. Agents can succeed against different
authorities and silently disagree.

**Verdict:** Reject as a steady state. A read-only comparison during a bounded
pilot is useful; dual authority is not.

### 4. Keep the validated Markdown tracker

**Benefit:** Exact Git history, offline access, deterministic validation, one
cross-client contract, atomic local mutation, and no service or token dependency.

**Cost:** No native comments, notifications, relation UI, board, or ordinary
GitHub issue discovery. Human collaboration requires repository edits and PRs.

**Verdict:** Current recommendation until the pilot proves that hosted workflow
benefits exceed the migration and operational costs.

## Decision matrix

Scores are recommendation judgments from 1 (poor) to 5 (strong). Weighted totals
are out of 5.

| Criterion | Weight | All 59 | Active only + archive | Dual-write | Keep local |
|---|---:|---:|---:|---:|---:|
| Historical fidelity | 25% | 3 | 4 | 4 | 5 |
| Single-authority simplicity | 20% | 4 | 4 | 1 | 5 |
| Agent reliability | 20% | 4 | 4 | 1 | 5 |
| Hosted collaboration UX | 15% | 5 | 4 | 4 | 1 |
| Reversibility | 10% | 3 | 5 | 5 | 5 |
| Ongoing operating cost | 10% | 4 | 4 | 1 | 4 |
| **Weighted total** | **100%** | **3.80** | **4.10** | **2.60** | **4.30** |

The matrix does not mean migration is never worthwhile. It says the current
validated system wins without evidence that this repository actually needs the
hosted collaboration advantage. Active-only is the strongest migration shape.

## Reversible private-repository pilot

Use a new private scratch repository owned by the same account. Do not pilot in
the public target: test issues can trigger notifications and leave misleading
activity or links.

### Representative set

Select 8-12 records that jointly cover:

- open, in-progress fixture, done, and wontfix mappings;
- all four local types and all controlled metadata dimensions;
- a `parent-plan`, active-to-active reference, active-to-terminal reference,
  code fences, links, quoted values, Unicode, the largest body, and the maximum
  observed tag count;
- one issue deliberately edited in GitHub after import to test drift refusal.

The in-progress case can be a generated pilot fixture derived from an open issue;
do not mutate the source corpus merely to obtain that state.

### Procedure

1. Capture the exact source commit and create a reviewed, hash-bound manifest.
2. Confirm the scratch repository is private and empty, Issues is enabled, and
   the token has issue write access. Grant project scope only for a separate,
   optional Projects v2 experiment.
3. Pre-create the controlled labels with descriptions. Do not depend on issue
   types, issue fields, Projects, or issue forms for the base pilot.
4. Run a dry-run that emits every planned request without network mutation.
5. Import serially through versioned REST, persist each returned ID, and read it
   back immediately.
6. Interrupt the run after several creates, restart it, and prove zero duplicate
   markers and zero duplicate issues.
7. Complete second-pass links, closures, and state reasons. Compare REST,
   GraphQL, `gh issue list/view --json`, and browser rendering.
8. Exercise the same list/show/start/close operations through Claude Code,
   OpenCode, Pi, and a human shell using one wrapper contract.
9. Export every target issue, compare it to the manifest, and preserve the pilot
   report before deleting the scratch repository.

### Pass criteria

- 100% title, body, summary, label, provenance-marker, state, and close-reason
  parity for the representative set.
- Zero duplicate issues after interrupted-run recovery.
- All source IDs resolve uniquely to target IDs; all selected links resolve.
- A manually drifted target is refused rather than overwritten.
- Missing permissions and injected `403`, `422`, and rate-limit responses stop or
  resume according to the documented policy without data loss.
- All four supported operators return equivalent records and lifecycle results.
- Browser presentation is readable without exposing machine metadata as noise.
- The maintainer can name at least one recurring workflow materially improved by
  GitHub comments, notifications, relations, or views.

Failure of any integrity or duplicate criterion blocks migration. A merely nicer
browser view is not enough to replace a validated source of truth.

## Safe production cutover

If the pilot passes and migration is approved:

1. **Recheck prerequisites.** Repeat the deprecation check, repository ownership,
   visibility, Issues setting, empty/nonempty target inventory, CLI version,
   API version, token scopes, label plan, and project decision.
2. **Approve one manifest.** Bind all 59 archive records and the 37 active import
   records to the source commit and exact before/planned hashes. Record every
   expected target mutation.
3. **Open a short write freeze.** The Markdown tracker remains authoritative but
   receives no lifecycle writes while import and verification run.
4. **Import in two passes.** Create and verify all 37 active issues first; then
   rewrite references and apply explicit relations. There are currently no
   in-progress records or terminal records in this import strategy.
5. **Prove parity.** Compare active ID sets, bodies, labels, statuses, target
   mappings, links, and a complete paginated export. Re-run the importer and
   require a no-op result.
6. **Switch authority once.** In one reviewed repository change, supersede
   ADR-0007, replace the issue skill and root instructions, change or retire
   `scripts/issues` and its CI gate, mark the 59-file corpus as a read-only
   archive, and add an independent hash check for that archive.
7. **Observe before cleanup.** Keep the cutover manifest, source commit, archive,
   importer, and rollback procedure available through an agreed stabilization
   window. Do not remove recovery assets immediately after success.

The source-of-truth switch happens only after hosted parity is proved. Avoid a
state where both trackers accept writes or neither does.

## Rollback

### Before the authority switch

The local tracker is unchanged and remains authoritative. Stop the importer. If
the production target contains only manifest-owned imports and no human activity,
remove only the issues identified by the manifest or disable Issues after
review. Never infer ownership from an issue-number range. Preserve the failed
manifest and API responses for diagnosis.

### After the authority switch

Do not delete hosted activity. Instead:

1. freeze new GitHub issue writes and export all issues, comments, labels,
   relations, state reasons, authors, and timestamps;
2. use the immutable 59-record archive as the base and construct a reviewed
   Markdown delta for every post-cutover GitHub issue and event, retaining GitHub
   URLs and native metadata as provenance;
3. validate the reconstructed local corpus and test agent operations;
4. restore the local source-of-truth policy and CLI in one reviewed change; and
5. close and lock hosted issues with a rollback notice, or disable Issues only
   after confirming that no unexported work becomes inaccessible.

This rollback is intentionally asymmetric. GitHub activity can be represented in
Markdown, but its comments and timeline cannot be recreated as the original
local edit history.

## Criteria to supersede ADR-0007

Write a superseding ADR only when all of these are true:

1. The private pilot passes every integrity, restart, permissions, and agent
   criterion above.
2. The maintainer explicitly accepts that original GitHub numbers, native
   authors, timestamps, and timelines cannot be preserved.
3. Active-only versus full-history scope is decided; if active-only is selected,
   the archive location, immutable commit, hash gate, and permalink policy are
   approved.
4. One canonical mapping exists for every local field, including in-progress,
   triage roles, `parent-plan`, and terminal reasons.
5. One wrapper gives Claude Code, OpenCode, Pi, and humans equivalent validated
   operations and fails closed on pagination, permission, and drift errors.
6. The repository has demonstrated a concrete recurring benefit from hosted
   comments, notifications, relations, search, or Projects—not only theoretical
   feature availability.
7. Cutover and post-cutover rollback have both been rehearsed from immutable
   manifests and exports.
8. The superseding change removes dual authority: GitHub becomes the sole active
   tracker, and Markdown becomes an explicitly read-only archive.

Until then, ADR-0007 remains accepted.

## Issue-template and community operating guidance

If GitHub becomes authoritative, add a small set of repository-owned templates
after cutover rather than during import. GitHub's official quickstart recommends
a descriptive title and a body containing purpose and resolution-relevant detail;
for bugs, that includes reproduction steps, expected behavior, and actual
behavior. GitHub templates can supply default title text, labels, type, and
assignees. Issue forms can require structured inputs, but remain public preview.

Recommended operating shape:

- one bug template with current behavior, expected behavior, reproduction,
  environment, and logs;
- one work/idea template aligned with Why this exists, Scope, and Open decisions;
- `blank_issues_enabled: false` for ordinary contributors while GitHub's
  maintainers-only blank issue remains available;
- concise labels with descriptions, controlled namespaces, and exactly one
  triage role; and
- triage responses as comments with explicit next action, preserving edit
  history instead of silently rewriting discussion.

Primary sources: [GitHub Issues quickstart](https://docs.github.com/en/issues/tracking-your-work-with-issues/configuring-issues/quickstart),
[configuring issue templates](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/configuring-issue-templates-for-your-repository),
[issue-form syntax](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/syntax-for-issue-forms),
and [managing labels](https://docs.github.com/en/issues/using-labels-and-milestones-to-track-work/managing-labels).

## Unresolved questions

- Is user ownership permanent, or would an organization-owned repository be
  considered to obtain organization issue types and eligible issue fields?
- Is Projects v2 valuable enough to justify additional scopes and a second
  lifecycle query surface?
- Must the 22 terminal records be searchable in GitHub, despite synthetic native
  dates and events?
- Should any dated AI triage sections become comments, or should all imported
  prose remain in one body to avoid false comment attribution?
- What official label-count and content-size constraints apply at execution
  time? The current official endpoint schemas inspected here do not establish
  the needed maximums; the pilot must test the actual corpus without guessing.
- Which GitHub identity should own automated issue mutations, and how will each
  agent receive least-privilege credentials without exposing them in prompts or
  logs?
- What stabilization window and evidence threshold are sufficient before
  retiring the local mutation implementation?

## Sources and authority

### Curated skill guidance

The `research` skill requires primary sources, explicit citations, one Markdown
artifact, and placement in the repository's established research-note location.
The `repository-issues` skill supplies the current local schema and ownership
contract. Those skills govern the method; they do not decide the migration.

### Repository evidence

- `docs/decisions/0007-use-validated-markdown-records-as-the-issue-tracker.md`
- `docs/plans/2026-08-21-001-feat-repository-issue-management-plan.md`
- `docs/agents/issue-tracker.md`
- `docs/agents/triage-labels.md`
- `.opencode/skills/repository-issues/SKILL.md`
- `scripts/issues`
- `tests/test_issues.py`
- the 59 canonical records under `docs/issues/`

### First-party GitHub evidence

- [REST API endpoints for issues](https://docs.github.com/en/rest/issues/issues)
- [REST API endpoints for comments](https://docs.github.com/en/rest/issues/comments)
- [REST API endpoints for labels](https://docs.github.com/en/rest/issues/labels)
- [REST API endpoints for events](https://docs.github.com/en/rest/issues/events)
- [REST API endpoints for timeline](https://docs.github.com/en/rest/issues/timeline)
- [REST API endpoints for sub-issues](https://docs.github.com/en/rest/issues/sub-issues)
- [REST API endpoints for dependencies](https://docs.github.com/en/rest/issues/issue-dependencies)
- [GraphQL issues reference](https://docs.github.com/en/graphql/reference/issues)
- [GraphQL Projects reference](https://docs.github.com/en/graphql/reference/projects)
- [Projects v2 API guide](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects)
- [Projects built-in automations](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-built-in-automations)
- [REST rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
- [GraphQL rate limits](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api)
- [REST best practices](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)
- [`gh issue create`](https://cli.github.com/manual/gh_issue_create),
  [`gh issue edit`](https://cli.github.com/manual/gh_issue_edit),
  [`gh issue list`](https://cli.github.com/manual/gh_issue_list),
  [`gh issue view`](https://cli.github.com/manual/gh_issue_view), and
  [`gh api`](https://cli.github.com/manual/gh_api)

## Limitations

- No GitHub issue or private pilot repository was created, edited, or deleted.
- The current target settings, token scopes, API schema, and empty issue list are
  point-in-time observations from 2026-09-13.
- The research did not infer undocumented GitHub limits. Where official current
  documentation was insufficient, the question remains open for the pilot.
- GitHub.com is the target evaluated here. GitHub Enterprise Server versions may
  expose different feature and API surfaces.
- A background peer-research attempt was refused before launch because the
  repository contains `.codegraph`, a symlink outside the scan root. No content
  was sent to that peer; all online findings above were independently checked
  against first-party pages.
