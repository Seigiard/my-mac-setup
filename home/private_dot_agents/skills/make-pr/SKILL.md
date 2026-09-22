---
name: make-pr
description: Ship the current branch as a pull request with a reviewer-first body, screenshot evidence, and the follow-through (issue comment, explanation page, babysit checkpoint), or rewrite the description of an existing PR. Use when the user asks to make, open, or ship a PR, to write or rewrite a PR description, or asks in Russian ("сделай PR", "открой пулл-реквест", "заливай", "перепиши описание PR").
---

# Make PR

Commit, capture evidence, describe, publish, explain, check. The body follows `references/pr-body-template.md` inside the repository's own PR contract when it has one; the rule it must satisfy is `~/.claude/rules/pull-requests.md`.

## Modes

| Invocation | Steps |
|---|---|
| none | Full flow, steps 1 to 9. |
| `describe [PR number or URL]` | Description only: steps 1, 4, 5, then `gh pr edit` with the new body and the PR URL printed. The PR is the given one, else the open PR of the current branch; with neither, stop and say so. Existing evidence links and frames in the old body are reused; no new capture. No commit, push, issue comment, explanation page, or babysit. |
| `--no-evidence` | Skip step 3; the Visuals line says why. |

## Workflow

### 1. Resolve the range, the PR state, and the repository's contract

```bash
base=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||'); base=${base:-main}
branch=$(git branch --show-current)
git log --oneline "$(git merge-base "$base" HEAD)"..HEAD
gh pr list --state open --head "$branch" --json number,url,title,body,headRepositoryOwner
```

Only an exit-0 `[]` means "no PR yet". A non-zero exit is unknown: stop and show it. With results, take the entry whose head owner and branch match this checkout; an ambiguous match stops here too. On the default branch, stop: a PR needs a branch.

Every repository may carry its own PR contract; this skill reads it rather than assuming one. Look, in order, at `.github/PULL_REQUEST_TEMPLATE.md`, then a PR-body section in `AGENTS.md` or `CLAUDE.md`; with neither, the template in `references/` stands alone. From the contract note three things: section headings, evidence rules, and any commands it documents for screenshots, image hosting, or demo pages. Also note the ticket key in the branch name or existing title (`[A-Z]+-\d+`).

### 2. Commit what is pending

Uncommitted changes go through the `ce-commit` skill. Done when `git status` is clean.

### 3. Capture evidence

Decide from the diff whether the change has a visible surface (routes, components, stories, styles, CLI output).

- **Visible surface**: start the app the way the repository documents and drive the branch with the Playwright tools (`browser_navigate`, `browser_take_screenshot`), one PNG per state the reviewer must see, saved under `/tmp/<slug>/evidence/<nn>-<caption>.png`. A "before" frame comes from the base only when a checkout of it is already running; otherwise the Before line describes it in words. When the app cannot be started in this session, fall back to the affected Storybook stories, then to terminal capture, and say which.
- **No visible surface**: capture the behavioural evidence running (test output, logs) as text; no images.

Host the frames with the image publisher or demo-page command the repository's contract documents; GitHub offers no CLI upload for PR images, so the repository is the only source of a URL. With no documented publisher, keep the local paths, list them in the report, and write the Visuals line as `![caption](attach: <path>)` for the user to drag into the PR. Done when every frame has a caption and either a URL or a listed path.

### 4. Write the stakeholder block

Invoke the `explain-for-manager` skill for the resolved range, take its block verbatim, and continue here; it opens the body and is reused in step 7.

### 5. Compose title and body

Read `references/pr-body-template.md` and fill every slot. When step 1 found a repository contract, keep its headings and place each slot under the section it belongs to; the stakeholder block still comes first. The Shape section uses the `show-me` skill's view families. Done when the draft passes the rule in `~/.claude/rules/pull-requests.md`, every slot cap, and `git ls-files <path>` returns every path the body mentions.

Rewriting an existing body keeps three things verbatim: any region between paired HTML comment markers (`<!-- name --> … <!-- /name -->`, written by CI or a bot), existing `Fixes`/`Related` references, and evidence frames or links that are still true. Rebuild the rest.

Title: imperative, under 70 characters, the outcome rather than the mechanism, keeping the ticket key prefix (`ABC-123: …`) when the branch or existing title carries one.

Write the body to a temp file. `gh` exits 0 with an empty body when the body arrives on stdin, so the file is the only accepted route.

### 6. Publish

```bash
git push -u origin "$branch"
gh pr create --title "$title" --body-file "$body_file"   # no PR yet
gh pr edit "$number" --title "$title" --body-file "$body_file"   # existing PR, after re-checking step 1
```

Re-run the step 1 PR check right before `gh pr create`. Print the PR URL.

### 7. Post the summary to the related issue

When the body carries `Fixes #N` or `Related: … #N` and the issue is open, add one comment with the stakeholder block and the PR link:

```bash
gh issue comment "$N" --body-file "$summary_file"
```

The comment begins with the block from step 4, followed by one line: `Delivered in <PR URL>.` Skip when no GitHub issue is referenced and say so in the report.

### 8. Explain the diff

Run the `explain-diff-html` skill in a subagent with the PR number and `--evidence /tmp/<slug>/evidence` when step 3 captured frames. It opens the page in the browser and returns its final `Explanation:` line; carry that path into the report.

### 9. One babysit checkpoint

Invoke the `ce-babysit-pr` skill with `<PR number> checkpoint`. It runs one tick over CI, reviews, and conflicts and prints how to resume; switching to watch mode is the user's call.

## Report

Six lines, in this order: PR URL, evidence (frame count and where they are hosted, or why none), issue comment URL or "no related issue", explanation path, babysit verdict, what the user should do next.
