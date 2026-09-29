---
name: make-pr
description: Ship the current branch as a pull request, from evidence and body to publish and follow-through, or rewrite an existing PR's description. Use when the user asks to make, open, or ship a PR, to write or rewrite a PR description, or asks in Russian ("сделай PR", "открой пулл-реквест", "заливай", "перепиши описание PR").
---

# Make PR

Commit, capture evidence, describe, publish, check. The body follows `references/pr-body-template.md`; the rule it must satisfy is `~/.claude/rules/pull-requests.md`.

## Modes

| Invocation | Steps |
|---|---|
| none | Full flow, steps 1 to 8. |
| `describe [PR number or URL]` | Steps 1, 4, 5, then the `gh pr edit` line of step 6 and the PR URL. The PR is the given one, else the open PR of the current branch; with neither, stop and say so. |
| `--no-evidence` | Step 3 skipped; the Visuals line says why. |

## Workflow

### 1. Resolve the range, the PR state, and the repository's contract

```bash
base=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||'); base=${base:-main}
branch=$(git branch --show-current)
git log --oneline "$(git merge-base "$base" HEAD)"..HEAD
gh pr list --state open --head "$branch" --json number,url,title,body,headRepositoryOwner
```

Only an exit-0 `[]` means "no PR yet". A non-zero exit is unknown: stop and show it. With results, take the entry whose head owner and branch match this checkout; an ambiguous match stops here too. On the default branch, stop: a PR needs a branch.

A repository may carry its own PR contract, and this skill reads it rather than assuming one: `.github/PULL_REQUEST_TEMPLATE.md` first, then a PR-body section in `AGENTS.md` or `CLAUDE.md`. From it take three things: section headings, evidence rules, and the commands it documents for screenshots, image hosting, or demo pages. Also resolve the work item the PR belongs to, taking the first source that has one: references already in the existing PR body, the issues GitHub links to the PR (`gh pr view --json closingIssuesReferences`), a ticket key (`[A-Z]+-\d+`) in the commit subjects or existing title, and last the branch name.

### 2. Commit what is pending

Uncommitted changes go through the `ce-commit` skill. Done when `git status` is clean.

### 3. Capture evidence

Read `references/evidence.md` and follow it. Done when every frame has a caption, a URL or a listed local path, and a named hosting route for step 6 to act on, or the change has no visible surface and its behavioural proof is captured as text.

### 4. Write the stakeholder block

Invoke the `explain-for-manager` skill for the resolved range, take its block verbatim, and continue here; it opens the body and is reused in step 7.

### 5. Compose title and body

Read `references/pr-body-template.md` and fill every slot. With a repository contract from step 1, keep its headings and place each slot under the section it belongs to; the stakeholder block still comes first. Where the contract states a rule explicitly, that rule beats the slot's own: a mandated format, a forbidden section, a different cap. The Shape section uses the `show-me` skill's view families. Done when the draft passes the rule in `~/.claude/rules/pull-requests.md`, every slot cap (the word cap counts the slots, not the sections a contract adds), and `git ls-files <path>` returns every repository path the body links, with evidence references awaiting `--attach` exempt because `gh` rewrites those to uploaded URLs at publish.

An existing body is rebuilt around three things kept: regions between paired HTML comment markers (`<!-- name --> … <!-- /name -->`, written by CI or a bot) verbatim; existing `Fixes`/`Related` references, folded into the single `Related:` line; and evidence frames or links that are still true.

Title: imperative, under 70 characters, the outcome rather than the mechanism, keeping the ticket key prefix (`ABC-123: …`) when step 1 resolved one.

Write the body to a temp file. `gh` exits 0 with an empty body when the body arrives on stdin, so the file is the only accepted route.

### 6. Publish

```bash
git push -u origin "$branch"
gh pr create --title "$title" --body-file "$body_file"   # no PR yet
gh pr edit "$number" --title "$title" --body-file "$body_file"   # existing PR, after re-checking step 1
```

Re-run the step 1 PR check right before `gh pr create`. Print the PR URL.

On route 2 of `references/evidence.md`, add one `--attach <path>` per frame to the publishing command.

A failed upload exits non-zero after the PR is already created or edited, so the exit status does not say whether the PR exists: read the URL `gh` prints and check the body before running anything again. Frames that did not upload fall back to route 3.

### 7. Post the summary to the related issue

When the body carries `Fixes #N` or `Related: … #N` and the issue is open, add one comment with the stakeholder block and the PR link:

```bash
gh issue comment "$N" --body-file "$summary_file"
```

The comment begins with the block from step 4, followed by one line: `Delivered in <PR URL>.` Without a GitHub issue reference, say so in the report and move on.

### 8. Babysit the PR

Write the report below first, so the user has the PR URL before anything long-running starts. Then invoke the `ce-babysit-pr` skill with the PR number and stay in its default watch mode until it reaches a stop condition; its own final report ends the run.

Pass `checkpoint` only when the user asked for a single tick, or said this session must stay free.

## Report

Finish in the language used in the chat, in this order:

1. **PR status:** PR URL, evidence (frame count and where they are hosted, or why none), issue comment URL or "no related issue", and what the user should do next. The babysit verdict is not part of this report; `ce-babysit-pr` reports it when the watch stops. In `describe` mode, report the updated PR and omit checks and actions that mode did not run.
2. **For the manager:** reuse the stakeholder block written into the PR in step 4. Translate it into the chat language when needed, preserving its meaning and claims.
3. **Optional explanation:** when the PR is large or complex, offer to create an `explain-diff-html` page and briefly name what would benefit from a visual walkthrough (for example, changes across several subsystems, a migration, or a non-obvious control flow). Run that skill only if the user accepts the offer. Omit the offer for a small, straightforward PR.
