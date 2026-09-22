---
name: explain-diff-html
description: Produce a rich, self-contained HTML explanation of a code change (branch, PR, commit, or working tree) with a two-level background, a grouped code walkthrough, and review risks, then open it in the browser. Use when the user asks for a detailed explanation of a diff, branch, or PR, asks in Russian ("объясни диф", "объясни PR", "разбери ветку", "что поменялось и почему"), or when a PR workflow needs an explanation page for reviewers.
---

# Explain Diff (HTML)

Turn a code change into one self-contained HTML page a reviewer can read on a laptop or a phone. The page is written in Russian, keeps code and identifiers in English, and lands in `/tmp` with a date-prefixed name so it stays out of version control.

## Arguments

| Argument | Meaning |
|---|---|
| none | Current branch against the default branch (`main` or `master`). |
| `<number>` or a PR URL | That pull request, via `gh pr diff`. |
| `<sha>` or `<sha>..<sha>` | That commit or range. |
| `uncommitted` | Working tree against `HEAD`. |
| `--no-open` | Write the file and print the path, but do not open a browser. A calling workflow passes this. |

## Workflow

### 1. Resolve the change

Pick the diff source in this order: explicit argument, else the branch against the default branch.

```bash
base=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||'); base=${base:-main}
git diff --stat "$(git merge-base "$base" HEAD)"..HEAD
git log --oneline "$(git merge-base "$base" HEAD)"..HEAD
```

For a PR: `gh pr view <n> --json title,body,baseRefName,headRefName` and `gh pr diff <n>`. The PR body is input for Background and Risks, not a source of truth about what the code does.

If the diff is empty, stop and say so. Do not explain nothing.

State the resolved source in one line before doing anything else, so a wrong default is caught early.

### 2. Explore around the change

The diff alone cannot produce Background. Before writing:

- Read every touched file in full, not only the hunks.
- Follow the callers and callees of changed functions one level out.
- Read the tests that cover the touched code, changed or not.
- Note the domain terms the code uses. The page reuses them instead of inventing synonyms.

Collect two or three toy examples with concrete data (an input, the path it takes, the output) while reading. They feed the diagrams.

### 3. Write the page from the template

Copy `references/template.html` from this skill's directory and fill the slots marked `<!-- slot: ... -->`. Do not restyle it. The template already carries the table of contents, callouts, collapsible blocks, light and dark themes, phone layout, and the Mermaid loader.

The page has exactly these sections, in this order:

1. **Что изменилось** (lead). Three to five sentences: what the change does, why, and what the reader will be able to judge after reading.
2. **Фон**. Two levels:
   - **Для тех, кто впервые здесь**: a `<details>` block, open by default, describing the subsystem the change touches as if the reader has never seen the repository. Names the entities, where they live, how data flows between them.
   - **Что важно для этого изменения**: the narrow context the change depends on, with a data-flow diagram that carries example data.
3. **Разбор кода**. Group the hunks by purpose, not by file order. For each group: one paragraph on intent, then the relevant snippet in a `<pre class="diff">` block, then what to notice. Small mechanical changes (renames, imports, formatting) go into one short list at the end.
4. **Риски и на что смотреть ревьюеру**. A checklist: behaviour that changed for existing callers, edge cases the diff handles or skips, what tests cover and what they do not, migration or rollout concerns. Each item names a file or function so the reviewer can jump there.

### 4. Prose rules

- Russian prose. Identifiers, file paths, commands, and error text stay in English inside `<code>` or `<pre>`.
- Short sentences, one idea each. No em-dashes, no parentheticals.
- Lists for parallel things. Prose for an argument.
- A callout (`<aside class="callout">`) for a definition, an invariant, or an edge case that changes how the reader judges the code. At most one callout per screen.
- Every claim about behaviour points at the code that shows it. Do not describe what the PR body says the code does.

### 5. Diagram rules

- Never ASCII art.
- **UI mock**: simplified HTML of the screen the user sees, using the template's `.ui` classes. Use it for any change a user can see.
- **Data flow with example data**: HTML boxes and arrows using the template's `.flow` classes. Every box carries a concrete value from the toy examples, not a type name.
- **Sequence or state**: a Mermaid block (`<pre class="mermaid">`). Mermaid loads from a CDN, so these diagrams need network access to render. Prefer the HTML families when the page must work offline.
- Pick at most two diagram families per page and reuse them for the "before" and "after" cases so the reader compares like with like.

### 6. Save, check, open

File name: `/tmp/YYYY-MM-DD-explanation-<slug>.html`, where the date is today and the slug is the branch name or PR number in kebab-case.

Before saving, run these checks against the HTML source and fix any failure:

- Every code block is a `<pre>`. A styled `<div>` with code needs `white-space: pre-wrap`, or the browser collapses the newlines.
- Every `<h2>` has an `id` and appears in the table of contents.
- No `<script src>` other than the Mermaid loader from the template.
- The page contains no absolute paths from this machine except in the diff snippets.

Then:

```bash
[ "$(uname)" = Darwin ] && [ "$no_open" != 1 ] && open "$file"
```

Finish with exactly one final line so a calling workflow can parse it:

```
Explanation: /tmp/2026-09-22-explanation-<slug>.html
```

## When called from another workflow

A PR workflow calls this skill with the PR number or branch and `--no-open`. It needs only the final `Explanation:` line. Do not ask the user questions in that mode; when the change source is ambiguous, fall back to the default branch comparison and say so in the page's lead.
