---
name: explain-diff-html
description: Explain a code change (branch, PR, commit, or working tree) as one self-contained HTML page for reviewers. Use when the user asks for a detailed explanation of a diff, branch, or PR, including in Russian ("объясни диф", "разбери ветку", "что поменялось и почему"), or when a PR workflow needs an explanation page.
---

# Explain Diff (HTML)

Russian prose, English code and identifiers, one page built from `references/template.html`.

## Arguments

| Argument | Meaning |
|---|---|
| none | Current branch against the default branch. |
| `<number>` or a PR URL | That pull request, via `gh pr diff`. |
| `<sha>` or `<sha>..<sha>` | That commit or range. |
| `uncommitted` | Working tree against `HEAD`. |
| `--no-open` | Print the path only; a calling workflow passes this and reads the final `Explanation:` line. |

## Workflow

### 1. Resolve the change

Explicit argument first, else the branch against the default branch:

```bash
base=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||'); base=${base:-main}
git log --oneline "$(git merge-base "$base" HEAD)"..HEAD
git diff --stat "$(git merge-base "$base" HEAD)"..HEAD
```

For a PR, `gh pr view <n> --json title,body,baseRefName,headRefName` supplies the author's intent for Background and Risks; the code stays the only source for what the change does.

State the resolved source in one line before anything else, so a wrong default is caught early. An empty diff ends the run with that statement. When called from another workflow, resolve ambiguity yourself: compare against the default branch and say so in the page's lead.

### 2. Explore around the change

The diff alone cannot produce Background. Done when:

- every touched file has been read in full, not only its hunks;
- callers and callees of every changed function have been followed one level out;
- the tests covering the touched code have been read, changed or not;
- you hold the domain terms the code uses, for the page to reuse;
- you hold two or three toy examples with concrete data: an input, the path it takes, the output. They feed the diagrams.

### 3. Fill the template

Copy `references/template.html` and fill each `<!-- slot: ... -->` in place; the template owns structure and styling. What each slot needs:

- **Что изменилось**: three to five sentences on what the change does, why, and what the reader can judge after reading.
- **Фон, для тех, кто впервые здесь**: the subsystem the change touches, told to a reader who has never seen the repository. Names the entities, where they live, how data flows between them.
- **Фон, что важно для этого изменения**: the narrow context the change depends on, with a data-flow diagram carrying example data.
- **Разбор кода**: hunks grouped by purpose, not file order. Per group: one paragraph of intent, the snippet in `<pre class="diff">`, what to notice. Mechanical changes (renames, imports, formatting) collapse into one short list at the end.
- **Риски и на что смотреть ревьюеру**: a checklist of behaviour that changed for existing callers, edge cases handled or skipped, what tests cover and what they miss, migration or rollout concerns. Each item names a file or function.

### 4. Prose

- Russian prose; identifiers, paths, commands, and error text in English inside `<code>` or `<pre>`.
- Short sentences, one idea each, plain punctuation.
- Lists for parallel things, prose for an argument.
- A callout (`<aside class="callout">`) for a definition, an invariant, or an edge case that changes how the reader judges the code. At most one per screen.
- Every claim about behaviour points at the code that shows it.

### 5. Diagrams

Rendered diagrams only, from these families:

- **UI mock** (`.ui` classes): the screen the user sees, for any visible change.
- **Data flow with example data** (`.flow` classes): every box carries a concrete value from the toy examples, not a type name.
- **Sequence or state**: a `<pre class="mermaid">` block. Mermaid loads from a CDN, so the page needs network to render it; the HTML families work offline.

At most two families per page, reused for the before and after cases so the reader compares like with like.

### 6. Save, check, open

Path: `/tmp/YYYY-MM-DD-explanation-<slug>.html`, today's date, slug from the branch name or PR number in kebab-case.

Before saving, confirm in the HTML source:

- every code block is a `<pre>`; a styled `<div>` holding code carries `white-space: pre-wrap`, otherwise the browser collapses its newlines;
- the only `<script src>` is the template's Mermaid loader;
- absolute paths from this machine appear only inside diff snippets.

On macOS without `--no-open`, run `open "$file"`. Finish with exactly one final line:

```
Explanation: /tmp/2026-09-22-explanation-<slug>.html
```
