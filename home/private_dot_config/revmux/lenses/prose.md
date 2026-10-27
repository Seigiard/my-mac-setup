---
description: "prose — agent-facing text judged as instructions: pointer wording, hierarchy, completion criteria, leading words, contradictions with the documents it names"
---
## Lens: prose

Apply this lens only to changed files that an agent reads as instructions: skills and their
reference files, `AGENTS.md`, `CLAUDE.md`, agent rules, shared instruction documents, prompts,
and lens or profile text. When the change touches none of these, report nothing under this lens.

Read first: `~/.claude/skills/writing-for-agents/SKILL.md`, and
`~/.claude/skills/writing-for-agents/SKILL-MECHANICS.md` when a skill changed. Read every changed
agent-facing file in full, not only its hunks.

Apply every item to every such file:

- Trigger description: pointer wording that fires on the right branches, one trigger per branch.
- Progressive disclosure: what every branch needs stays inline; what only some branches reach
  sits behind a pointer; a concept's definition, rules and caveats sit under one heading.
- Unambiguous instructions: each step ends on a checkable completion criterion; leading words
  rather than restatements; positive phrasing rather than prohibition; no sentence the agent
  obeys by default; one source of truth per meaning.
- Consistency: no contradiction with another skill or shared document the text names, or that
  covers the same task. Search `~/.agents/skills/`, `~/.claude/skills/` and `~/.claude/shared/`
  when they exist in the checkout's environment.

Severity is `critical` when an agent following the text does the wrong thing, or when the text
contradicts another document in a way that changes behavior. Severity is `major` when an
instruction makes runs diverge: an ambiguous step, a missing completion criterion, a step the
text's own stated decision requires but omits. Severity is `minor` for wording or pruning with no
behavior change.

Every finding cites its file and line and quotes the text it concerns. Problems in unchanged
text belong in `pre_existing`.
