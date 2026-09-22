---
name: make-pr
description: Ship the current branch as a pull request with a reviewer-first body and the follow-through (issue comment, explanation page, babysit checkpoint), or rewrite the description of an existing PR. Use when the user asks to make, open, or ship a PR, to write or rewrite a PR description, or asks in Russian ("сделай PR", "открой пулл-реквест", "заливай", "перепиши описание PR").
---

# Make PR

Commit, describe, publish, explain, check. The body follows `references/pr-body-template.md`; the contract it must satisfy is `~/.claude/rules/pull-requests.md`.

## Modes

| Invocation | Steps |
|---|---|
| none | Full flow, steps 1 to 8. |
| `describe [PR number or URL]` | Description only: steps 1, 3, 4, then `gh pr edit` with the new body and the PR URL printed. The PR is the given one, else the open PR of the current branch; with neither, stop and say so. A `Fixes #N` or `Related:` line already in the body is kept verbatim. No commit, push, issue comment, explanation page, or babysit. |

## Workflow

### 1. Resolve the range and the PR state

```bash
base=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||'); base=${base:-main}
branch=$(git branch --show-current)
git log --oneline "$(git merge-base "$base" HEAD)"..HEAD
gh pr list --state open --head "$branch" --json number,url,body,headRepositoryOwner
```

Only an exit-0 `[]` means "no PR yet". A non-zero exit is unknown: stop and show it. With results, take the entry whose head owner and branch match this checkout; an ambiguous match stops here too. On the default branch, stop: a PR needs a branch.

### 2. Commit what is pending

Uncommitted changes go through the `ce-commit` skill. Done when `git status` is clean.

### 3. Write the stakeholder block

Invoke the `explain-for-manager` skill for the resolved range. Keep its block verbatim; it opens the body and is reused in step 6.

### 4. Compose title and body

Read `references/pr-body-template.md` and fill every slot; each slot carries its own cap. The Shape section uses the `show-me` skill's view families. Done when the draft passes the contract in `~/.claude/rules/pull-requests.md`, every slot cap, and `git ls-files <path>` returns every path the body mentions.

Title: imperative, under 70 characters, the outcome rather than the mechanism.

Write the body to a temp file. `gh` exits 0 with an empty body when the body arrives on stdin, so the file is the only accepted route.

### 5. Publish

```bash
git push -u origin "$branch"
gh pr create --title "$title" --body-file "$body_file"   # no PR yet
gh pr edit "$number" --title "$title" --body-file "$body_file"   # existing PR, after re-checking step 1
```

Re-run the step 1 PR check right before `gh pr create`. Print the PR URL.

### 6. Post the summary to the related issue

When the body carries `Fixes #N` or `Related: #N` and the issue is open, add one comment with the stakeholder block and the PR link:

```bash
gh issue comment "$N" --body-file "$summary_file"
```

The comment begins with the block from step 3, followed by one line: `Delivered in <PR URL>.` Skip when no issue is referenced and say so in the report.

### 7. Explain the diff

Run the `explain-diff-html` skill in a subagent with the PR number. It opens the page in the browser and returns its final `Explanation:` line; carry that path into the report.

### 8. One babysit checkpoint

Invoke the `ce-babysit-pr` skill with `<PR number> checkpoint`. It runs one tick over CI, reviews, and conflicts and prints how to resume; switching to watch mode is the user's call.

## Report

Five lines, in this order: PR URL, issue comment URL or "no related issue", explanation path, babysit verdict, what the user should do next.
