---
title: GitHub issue query flags - Issue 461 research
type: research
date: 2026-10-13
topic: gh-issue-query-flags
status: complete
execution: read-only-source-and-command-research
---

# GitHub issue query flags: issue 461

## Summary

Both documented listing commands fail on **gh 2.102.0**. Both proposed replacements work and preserve the issue-only results across page boundaries. The narrow correction belongs in `docs/agents/issue-tracker.md` and the canonical repository skill, `.claude/skills/repository-issues/SKILL.md`.

`gh issue view --comments --json ...` also fails, but the inspected repository instructions do not literally combine these flags. They omit the machine-readable alternative. In a non-TTY agent process, `--comments` alone returns comments **without the issue body**. Explicit JSON fields including `comments` solve both problems. A canned `gh` stub cannot prove the real CLI accepts its options; **zero new permanent tests** is the recommended outcome for this documentation correction.

## Scope and evidence limits

Observed on **2026-10-13 UTC**, in checkout revision `b9e060c86ea85c4cfcbb49f9553ce2eb083b2bc8`. The captured clock readings include `04:27:04Z` and `04:30:17Z`. Initial `git status --short` was empty. Installed versions returned:

```text
gh version 2.102.0 (2026-09-30)
https://github.com/cli/cli/releases/tag/v2.102.0
jq-1.8.2
```

The issue was read directly with:

```sh
gh issue view 461 --repo Seigiard/my-mac-setup --json number,title,body,labels,state,url,comments
gh api repos/Seigiard/my-mac-setup/issues/461 --jq '{number,state,comments,updated_at,html_url}'
```

Both returned status **0**. The issue was open, labeled `bug` and `ready-for-agent`, with `comments: []` in the view and a REST comment count of **0**. REST reported `updated_at: 2026-10-12T13:30:10Z`. Sources: [issue](https://github.com/Seigiard/my-mac-setup/issues/461), [issue API](https://api.github.com/repos/Seigiard/my-mac-setup/issues/461).

The body asserts repeated failures in sessions `d38a3cc9`, `56d0e430`, and `a22ef9ae`, based on 83 interactive sessions from October 5–11. **Those historical frequency claims were not verified here.** No Memex records were retrieved. Today's reproductions establish the defect, not its frequency or the provenance of past retries.

Research used GET requests, GraphQL reads through `gh issue view`, local source reads, and command comparisons. This report is the only repository addition. No implementation, issue mutation, deployment, commit, or push was performed.

## 1. Exact failures and their primary-source explanation

These are the complete commands from [`docs/agents/issue-tracker.md`](../agents/issue-tracker.md), lines **11–12**, also present in the repository skill at lines **29–30**:

```sh
gh api --paginate --slurp 'repos/Seigiard/my-mac-setup/issues?state=open&per_page=100' --jq 'add | map(select(has("pull_request") | not)) | .[] | [.number, .title, .html_url] | @tsv'
gh api --paginate --slurp 'repos/Seigiard/my-mac-setup/issues?state=all&per_page=100' --jq 'add | map(select(has("pull_request") | not)) | .[] | {number, state, title, body, url: .html_url}'
```

Each returned status **1**, empty stdout, and this first stderr line, followed by help:

```text
the `--slurp` option is not supported with `--jq` or `--template`
```

The separately reproduced incompatible issue-view command was:

```sh
gh issue view 461 --repo Seigiard/my-mac-setup --comments --json number,title,body,labels,state,url,comments
```

It returned status **1**, empty stdout, and:

```text
specify only one of --comments or --json
```

Exit codes were captured with Python `subprocess.run(..., capture_output=True, text=True)`, rather than inferred from error text. The commands were also invoked directly through the shell tool.

The installed release's source makes both restrictions explicit before the command reaches its API implementation:

- [`pkg/cmd/api/api.go`, lines 260–272][api-validation]: `Slurp` excludes `FilterOutput` and `Template`, and requires pagination.
- [`pkg/cmd/issue/view/view.go`, lines 59–63][view-validation]: `Comments` excludes the JSON exporter.
- Upstream already has rejection tests for [slurp with jq/template][api-tests] and [comments with JSON][view-tests]. These are intentional supported-interface constraints, not evidence of an upstream regression.

Source references are pinned to commit **`fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd`**, obtained from the [GitHub API tag ref for v2.102.0][gh-tag]. The jq tag ref resolves to **`34f7186b86743a083a589741b6cea95293524108`** ([API][jq-tag]). These map the reported versions to release source; the installed binaries were not independently build-attested.

`gh api --help`, `gh issue view --help`, and `gh help formatting` all returned status **0**. API help explains the outer page array and shows a working `--slurp ... | jq ...` example. Issue-view help lists `comments` among JSON fields, but does not explain the flag conflict. See the official [API manual][api-manual], [issue-view manual][view-manual], and [formatting manual][formatting].

## 2. Exact replacement candidates

### Candidate A: aggregate pages, then use external jq

```sh
gh api --paginate --slurp 'repos/Seigiard/my-mac-setup/issues?state=open&per_page=100' | jq -r 'add | map(select(has("pull_request") | not)) | .[] | [.number, .title, .html_url] | @tsv'
gh api --paginate --slurp 'repos/Seigiard/my-mac-setup/issues?state=all&per_page=100' | jq 'add | map(select(has("pull_request") | not)) | .[] | {number, state, title, body, url: .html_url}'
```

`gh --slurp` supplies an array of page arrays; `add` concatenates those arrays. External jq needs **`-r`** for actual TSV rather than quoted JSON strings. No extra jq `--slurp` is needed because gh already supplies the outer array. Sources: [gh API help][api-manual], [jq invocation and raw output][jq-manual], [jq `add`][jq-add], and [release implementation][jq-builtins]. Both `gh` and `jq` are already declared in [`Brewfile.tmpl`](../../home/private_dot_config/brewfiles/Brewfile.tmpl), lines **46, 65**.

Both exact pipelines above were executed in `zsh -o pipefail -c ...`. Pipeline status was **0**, stderr was empty, and output contained **27 TSV rows** and **159 JSON objects**, respectively. This checks the producer's failure status as well as jq's status. Without `pipefail`, the final jq exit code can hide a failed gh producer; a partial result must not count as a complete query.

A negative pipeline control appended `| jq .` to the exact invalid open-list command from section 1. `zsh -c ...` returned pipeline status **0** with empty stdout and the gh option error on stderr. `zsh -o pipefail -c ...` returned **1** for the same command. This directly demonstrates why an exit-zero-only pipeline check is insufficient.

### Candidate B: filter and project each page with built-in jq

```sh
gh api --paginate 'repos/Seigiard/my-mac-setup/issues?state=open&per_page=100' --jq '.[] | select(has("pull_request") | not) | [.number, .title, .html_url] | @tsv'
gh api --paginate 'repos/Seigiard/my-mac-setup/issues?state=all&per_page=100' --jq '.[] | select(has("pull_request") | not) | {number, state, title, body, url: .html_url}'
```

Both returned status **0**, empty stderr, and the same **27** and **159** issue records. This is the preferred narrow replacement: it preserves the outputs without an additional pipeline or external jq requirement. The [formatting manual][formatting] confirms that built-in `--jq` does not require an installed jq executable.

Removing only `--slurp` is insufficient: the old `add` would combine issue objects within each page instead of concatenating page arrays. Candidate B replaces the whole page-aggregation prefix with a record iterator and filter.

### Pagination and filter equivalence

The [repository issues API][issues-docs] includes pull requests, identified by `pull_request`; the filter is necessary. `per_page=100` is the maximum page size, not a total-result cap. Gh follows REST `Link` headers with `rel="next"` ([release source][pagination-source]). Filtering happens after page retrieval, so a page containing only pull requests does not stop pagination.

For the same sequence of pages, filtering and projecting each record commutes with concatenating those pages. Neither listing needs a global sort, total, or deduplication. Thus A and B preserve record order and fields. This argument applies to these filters; it does not make per-page aggregate queries equivalent to whole-result aggregates.

Live comparisons captured each gh and jq exit code before parsing output. Candidate A's page JSON stayed in memory and was passed to real jq. Candidate B made independent live requests. TSV outputs were compared **byte for byte**. JSON object streams were parsed with `jq -s '.'` and compared as **ordered full objects**, including `body`, against each other and the issue records from the raw page response.

| Query | Raw page lengths | Raw records | Excluded PRs | Issue records | TSV / full-object comparison |
|---|---|---:|---:|---:|---|
| `state=open&per_page=100` | `[28]` | 28 | 1 | 27 | Equal / equal |
| `state=all&per_page=100` | `[100,100,100,100,48]` | 448 | 289 | 159 | Equal / equal |
| `state=open&per_page=10` | `[10,10,8]` | 28 | 1 | 27 | Equal / equal |

All comparison commands returned **0**. The smaller open-page query changes only `per_page` in the candidates and proves page-boundary behavior without a local HTTP fixture. Raw all-state page number ranges were **463–364, 363–264, 263–149, 148–49, 48–1**. The first TSV row was:

```text
463	Calibrate the herdr-peer agent-list stub against the real herdr binary	https://github.com/Seigiard/my-mac-setup/issues/463
```

A separate diagnostic directly demonstrated per-page evaluation:

```sh
gh api --paginate 'repos/Seigiard/my-mac-setup/issues?state=open&per_page=10' --jq 'length'
gh api --paginate 'repos/Seigiard/my-mac-setup/issues?state=all&per_page=100' --jq '[.[] | select(has("pull_request") | not)] | length'
```

Statuses were **0**. Outputs were `10\n10\n8\n` and `52\n70\n37\n0\n0\n`. The latter continued through two pages with zero issues. The [response processor][per-page-source] applies jq to each HTTP response. A global total needs aggregation after pagination. In this release, unfiltered non-color REST array output can also join arrays through `paginatedArrayReader`; that separate path does not change filtered `--jq` evaluation.

API evidence endpoints: [open, 100 per page](https://api.github.com/repos/Seigiard/my-mac-setup/issues?state=open&per_page=100), [all, 100 per page](https://api.github.com/repos/Seigiard/my-mac-setup/issues?state=all&per_page=100), [open, 10 per page](https://api.github.com/repos/Seigiard/my-mac-setup/issues?state=open&per_page=10). These are live data, not frozen snapshots. Separate calls are not transactionally consistent; the comparisons matched during this observation window. Neither candidate promises snapshot isolation during concurrent issue changes.

## 3. Comments compatibility and completeness

The machine-readable candidate is:

```sh
gh issue view 461 --repo Seigiard/my-mac-setup --json number,title,body,labels,state,url,comments
```

It returned status **0** with the issue body and an empty comments array. The readable comments form is separately valid:

```sh
gh issue view 461 --repo Seigiard/my-mac-setup --comments
```

It returned status **0** but **zero stdout bytes** in this non-TTY process. The [view implementation][view-output] prints only the raw comment list when `--comments` is used outside a TTY. That command therefore cannot fulfill “read an issue and its history” when the agent needs the body too.

Issue **430** supplied a non-empty control. Both commands, with `461` replaced by `430`, returned **0**. JSON contained **4 comments** plus the body. `--comments` stdout was **5,244 bytes**, contained all four comment bodies, and omitted the issue body. Source: [issue 430 API](https://api.github.com/repos/Seigiard/my-mac-setup/issues/430) and [view output source][view-output]. No TTY rendering was tested.

There is **no fixed 100-comment truncation in this version's `gh issue view --json comments` path**: selecting the field triggers `preloadIssueComments`, which follows GraphQL comment cursors in batches of 100 until `hasNextPage` is false ([call site][comments-call], [pagination implementation][comments-source]). This is source evidence; the live controls had 0 and 4 comments, not more than 100. It must not be generalized to `gh issue list --json comments` or arbitrary GraphQL queries. If a raw REST comments read is used, its own pagination is required, for example `gh api --paginate 'repos/Seigiard/my-mac-setup/issues/461/comments?per_page=100' --jq '.[]'`.

## 4. Affected-file inventory and canonical ownership

| Path and lines | Observed role | Narrow follow-up scope |
|---|---|---|
| [`docs/agents/issue-tracker.md`](../agents/issue-tracker.md): **11–13, 39** | Two invalid listings; readable-only issue/history guidance | Replace listings; explain flag exclusivity and give JSON body-plus-comments reading |
| [`.claude/skills/repository-issues/SKILL.md`](../../.claude/skills/repository-issues/SKILL.md): **29–31, 70** | Canonical repository-owned skill; two invalid listings and readable-only verification guidance | Apply the same correction, including the non-TTY completion/read boundary |
| [`.opencode/skills/repository-issues`](../../.opencode/skills/repository-issues) | Tracked relative symlink to `../../.claude/skills/repository-issues` | Reaches the canonical content; no separate body to edit |
| [`.pi/settings.json`](../../.pi/settings.json): **2–5** | Pi includes `../.claude/skills` | Reaches the same skill; no separate copy |
| [`AGENTS.md`](../../AGENTS.md): **29–31, 159–161** | Symlink to `CLAUDE.md`; routes queries to the doc and skill | Existing routing already reaches the correction |
| [`tests/test_repository_issue_skill_discovery.py`](../../tests/test_repository_issue_skill_discovery.py): **11–33** | Tests shared skill discovery and adapter relationships | Existing coverage owns discovery, not CLI option validity |
| `~/.agents/skills/gh/SKILL.md`: **21, 39–40** | Deployed shared skill has correct comments guidance but still suggests jq plus optional slurp | Relevant conflicting guidance; upstream-owned content, separate from the local correction |
| [`home/private_dot_config/agent-skills/manifest`](../../home/private_dot_config/agent-skills/manifest): **7** | Selects `cli/cli gh` | Identifies the shared skill's declared upstream owner |

Repository search found **four physical offending listings**: two in the tracker doc and two in the canonical skill. Reading the OpenCode symlink exposed the same two skill listings, not another maintained copy. No offending snippets were found under `home/`. Git index mode `120000` and `git show HEAD:.opencode/skills/repository-issues` confirmed the symlink target; Pi's settings and the discovery test confirmed its route.

The shared skill's incompatible pagination advice also exists in [`cli/cli/skills/gh/SKILL.md` at the installed release commit][upstream-skill], lines **38–39**. The deployed comments sentence is absent from that release's skill text, so the live skill should not be described as an exact release copy. The inspected `~/.agents/.skill-lock.json`, lines **1–3**, had an empty `skills` object and did not identify its installed source commit. A shared-skill change needs its upstream/installation ownership resolved; editing the deployed file would not be a durable repository fix.

## 5. Testing recommendation and verification scope

**Recommendation: zero new permanent tests for the narrow prose correction.** The consumer is an agent querying repository work. The observable failures are rejected CLI options and missing body data. The independent oracle is the real installed gh interface, confirmed by release source and live positive controls. The repository owns its instructions and discovery adapters; upstream owns gh's option parser and pagination implementation.

A canned executable that always returns fixture JSON can accept the old invalid command and exit zero. A stub that hardcodes the two restrictions merely duplicates upstream validation. Neither proves CLI compatibility. A source grep for approved flags has the same problem: it protects text shape, not successful execution. A zero-exit assertion alone can also pass for empty or incomplete results, as the valid `--comments` call for issue 461 demonstrates.

This judgment follows [`semantic-regression-tests-over-source-shape.md`](../solutions/design-patterns/semantic-regression-tests-over-source-shape.md), lines **52–64, 68–75**, and `~/.claude/shared/testing.md`, lines **7–14, 24–30**. Existing discovery coverage was inspected first. The issue's requested bashunit stub is a hypothesis, not a mandatory sound test design.

For a later documentation correction, the focused evidence is the real-binary negative reproductions and positive replacement checks above, with status checked before output and a multi-page control. A live repository smoke test would be a real oracle but introduces credentials, network, and mutable data; it does not justify a new default `smoke_test.sh` gate for this narrow correction. If a separately accepted local executable integration later needs permanent coverage, real gh with a controlled HTTP transport can supply stable records and page links while retaining the real parser. That integration and harness are outside this research scope.

[`docs/agent-verification.md`](../agent-verification.md), lines **5–18, 20–25**, was read before command checks. This research changes no managed path or executable behavior, so no build, bashunit, Docker, or chezmoi suite was run or claimed as passed. A future doc/skill-only correction does not by itself change the adapters or add a `home/` deployment path. Any expansion into managed templates, installer behavior, or adapter paths requires a fresh risk classification and the corresponding canonical checks.

The report's whitespace check used `git diff --no-index --check /dev/null docs/research/2026-10-13-gh-issue-query-flags.md` so the untracked addition was included. It returned **1**, with no stdout or stderr diagnostics, while comparing the new file with `/dev/null`. Final `git status --short` showed only this report.

## Open questions

- Historical impact: the three session excerpts and the 83-session sample remain unverified. Source-grounded Memex records are needed before assigning a frequency or retry-cost estimate.
- Shared skill provenance: the declared owner is `cli/cli`, but the exact deployed skill commit is unknown. Resolve that ownership before proposing a durable shared-skill update.
- Comment page boundaries: the source follows cursors beyond 100 comments; that boundary was not exercised live. It is not needed to validate the two flag conflicts.
- Version range: only installed gh **2.102.0** and external jq **1.8.2** were executed. This report does not establish a minimum supported version or future CLI compatibility.

[gh-tag]: https://api.github.com/repos/cli/cli/git/ref/tags/v2.102.0
[jq-tag]: https://api.github.com/repos/jqlang/jq/git/ref/tags/jq-1.8.2
[api-validation]: https://github.com/cli/cli/blob/fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd/pkg/cmd/api/api.go#L260-L272
[view-validation]: https://github.com/cli/cli/blob/fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd/pkg/cmd/issue/view/view.go#L59-L63
[api-tests]: https://github.com/cli/cli/blob/fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd/pkg/cmd/api/api_test.go#L337-L350
[view-tests]: https://github.com/cli/cli/blob/fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd/pkg/cmd/issue/view/view_test.go#L64-L74
[api-manual]: https://cli.github.com/manual/gh_api
[view-manual]: https://cli.github.com/manual/gh_issue_view
[formatting]: https://cli.github.com/manual/gh_help_formatting
[issues-docs]: https://docs.github.com/en/rest/issues/issues#list-repository-issues
[pagination-source]: https://github.com/cli/cli/blob/fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd/pkg/cmd/api/pagination.go#L15-L23
[per-page-source]: https://github.com/cli/cli/blob/fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd/pkg/cmd/api/api.go#L509-L532
[jq-manual]: https://jqlang.org/manual/v1.8/#invoking-jq
[jq-add]: https://jqlang.org/manual/v1.8/#add
[jq-builtins]: https://github.com/jqlang/jq/blob/34f7186b86743a083a589741b6cea95293524108/src/builtin.jq#L3-L11
[view-output]: https://github.com/cli/cli/blob/fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd/pkg/cmd/issue/view/view.go#L186-L199
[comments-call]: https://github.com/cli/cli/blob/fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd/pkg/cmd/issue/view/view.go#L157-L162
[comments-source]: https://github.com/cli/cli/blob/fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd/pkg/cmd/issue/view/http.go#L11-L51
[upstream-skill]: https://github.com/cli/cli/blob/fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd/skills/gh/SKILL.md#L16-L39
