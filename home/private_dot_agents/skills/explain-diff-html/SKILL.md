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
| `--evidence <dir>` | PNG frames captured by make-pr, the first source for step 3. |

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

### 3. Collect frames

Real pixels beat drawings. Take the first source that yields frames, in this order:

1. `--evidence <dir>`: every PNG there.
2. Images already in the PR body (`![caption](url)`): download each and keep its caption.
3. A visible surface with no frames yet: start the app or the affected Storybook stories the way the repository documents and capture with the Playwright tools, following `~/.agents/skills/make-pr/references/evidence.md`.
4. Only when none of these produced a frame: a `.ui` mock, and the caption says it is a sketch.

Embed frames as data URIs so the page stays self-contained. Done when every visible state the reader must see has a frame or a labelled sketch.

### 4. Fill the template

Copy `references/template.html` and fill each `<!-- slot: ... -->` in place; the template owns structure and styling on the render kit in `~/.claude/shared/render-kit.md`, which names every class and component the page may use. The page `<title>` and `<h1>` are the PR title, else the first commit subject of the range. Length follows the change: a two-file fix makes a short page, a forty-file feature a long one. Each slot has a shape, the shape is the only gate, and a slot holds exactly what its shape asks for:

- **Для нетехнических читателей**: the stakeholder block as four `<dt>`/`<dd>` rows of the `dl.rows` grid. When the change is a PR whose body already opens with a `**For non-engineers.**` block, translate it and keep its four slots; otherwise invoke the `explain-for-manager` skill with `--lang ru` for the resolved range and continue here. It sits first so a manager can stop reading after it.
- **Что изменилось**: three to five sentences on what the change does, why, and what the reader can judge after reading, then the frames from step 3 as `<figure>` elements. A caption is one sentence on what the reader should see in the frame, the story or route name last in `<small>`; the template numbers the frames itself. Two narrow frames that compare states sit side by side in a `<div class="grid">`. A rule the reader must hold to judge the code (an access rule, an ordering guarantee) follows the lead as one `<blockquote>` callout, in one or two sentences.
- **Фон, для тех, кто впервые здесь**: the subsystem the change touches, told to a reader who has never seen the repository, collapsed by default. Names the entities, where they live, how data flows between them, and stops at what a newcomer needs to follow the walkthrough.
- **Разбор кода**: the shape of the change, in the `show-me` skill's view families. One group per family of changes the diff contains, named by purpose: ten groups for a large feature, one for a small fix. A group is one sentence of intent followed by one sketch (a call tree, file tree, or pseudocode as a `<div class="shj-lang-diff">` whose changed lines start with `+` or `-`; the highlighter colours them) and ends at the sketch: the sketch carries the detail, the sentence says why the group exists. The hunks themselves stay in the diff; mechanical changes (renames, imports, formatting) collapse into one list at the end.
- **Риски и на что смотреть ревьюеру**: one checkbox item per risk the reviewer would otherwise miss: behaviour that changed for existing callers, edge cases handled or skipped, what tests cover and what they miss, migration or rollout concerns. Each item names a file or function.

### 5. Prose

- Russian prose; identifiers, paths, commands, and error text in English inside `<code>` or a `shj-lang-*` block.
- Short sentences, one idea each, plain punctuation.
- Lists for parallel things, prose for an argument.
- A callout (`<blockquote>`) for an edge case or a rule that changes how the reader judges the code. At most one per screen.
- Every claim about behaviour points at the code that shows it.
- An editor pass at the end: a term the reader would have to look up (инвариант, идемпотентность, грант, миграция, предикат, бэкфилл) is either replaced by what it means here or defined once at first use, as `<dfn data-tooltip="…">` for a phrase or a callout for a paragraph.

### 6. Diagrams

Rendered diagrams only, from these families:

- **Frames** from step 3 for anything the user sees; a `.ui` mock only as the labelled fallback there.
- **Data flow with example data** (`.flow` classes): every box carries a concrete value from the toy examples, not a type name.
- **Sequence or state**: a `<pre class="mermaid">` block, rendered by the template's Mermaid loader.

The content picks the family: a frame for what the user sees, a `.flow` for data changing shape, a sequence diagram for the order of calls between parties, a state diagram for a lifecycle. A before and an after case use the same family so the reader compares like with like.

### 7. Save, check, open

Path: `/tmp/YYYY-MM-DD-explanation-<slug>.html`, today's date, slug from the branch name or PR number in kebab-case. This path is fixed: a session's scratchpad or temp-directory guidance does not move it, because the user and calling workflows look here.

Before saving, confirm in the HTML source:

- every code block is a `<div class="shj-lang-…">` with `<`, `>` and `&` escaped as entities; sketches are `shj-lang-diff` with raw `+` and `-` lines and no spans of your own;
- the only external resources are the template's Pico stylesheet, the speed-highlight theme and loader, and the Mermaid loader;
- absolute paths from this machine appear only inside diff snippets.

On macOS without `--no-open`, run `open "$file"`.

To publish the page as a Claude Artifact, publish the copy that `python3 ~/.claude/shared/render-kit/inject-styles.py "$file" -o <copy>` writes: Artifacts block external stylesheets, so the copy carries the CSS inside the file. The `/tmp` file itself keeps its links.

Finish with exactly one final line:

```
Explanation: /tmp/2026-09-22-explanation-<slug>.html
```
