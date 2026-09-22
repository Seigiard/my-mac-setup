---
name: explain-for-manager
description: Write the non-technical summary of a code change or technical problem for a product owner or manager, in the shape problem, impact, what was done, what you will notice. Use when the user asks to explain a change or tech debt for non-engineers or stakeholders, asks in Russian ("объясни для менеджера", "как это продать продакту", "что это даёт бизнесу"), or when make-pr or explain-diff-html needs the stakeholder section.
---

# Explain for a manager

Translate one technical change into language a product owner reads at sprint planning. The reader must come away knowing **why** it was worth doing, not what was done to the code.

## Arguments

| Argument | Meaning |
|---|---|
| none | The current branch against the default branch. |
| `<PR number or URL>`, `<sha>`, `<sha>..<sha>`, `uncommitted` | That change, resolved the same way explain-diff-html does. |
| a sentence | A problem or tech-debt item to pitch instead of a diff. |
| `--lang ru` | Russian output. Default is English. |

## Workflow

1. **Know the change.** For a diff: the commit messages, the diff, and enough surrounding code to say what a user or teammate could not do before. For a pitched problem: the code that hurts and who feels it. Done when you can name the person who notices the difference.
2. **Fill the four slots**, in this order, one to two sentences each:
   - **Problem**: what was wrong or missing, seen from the person who felt it, without naming components.
   - **Impact**: what it cost, in time, errors, blocked work, or numbers. This slot carries the "why"; when it is weak, the whole block fails.
   - **What was done**: the change as a capability, one sentence. A refactor with no visible effect says so plainly: "nothing changes in daily use; this makes X possible next".
   - **What you will notice**: the visible result, or the honest "nothing yet, this is groundwork for X". State what is still not done when a reader could assume otherwise.
3. **Run the reader test.** Read the block as the product owner. If they could not answer "why do this" from the Impact slot alone, rewrite that slot before anything else.

## Output

One Markdown block, nothing before or after it:

```markdown
**For non-engineers.** Problem: … Impact: … What was done: … What you will notice: …
```

In Russian (`--lang ru`) the label is **Для нетехнических читателей.** and the slot names are Проблема, Влияние, Что сделано, Что вы заметите.

Plain words throughout: no file names, class names, commands, or acronyms unless the reader already uses them daily. Domain terms come from the repository's own vocabulary (CONCEPTS.md or CONTEXT.md when present).
