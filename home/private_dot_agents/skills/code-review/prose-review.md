# Prose review brief

Review a diff of agent-facing text and report findings only. Edit nothing, commit nothing,
and run no tests.

## Inputs

The prompt supplies the checkout, base SHA, changed paths, source decisions, and report path.

## Read before judging

- `~/.claude/skills/writing-for-agents/SKILL.md`
- `~/.claude/skills/writing-for-agents/SKILL-MECHANICS.md` when a skill changed
- Every changed file in full
- `git diff <base> -- <path>` for every changed path

## Rubric

Apply every item to every changed file:

- Trigger description: pointer wording and one trigger per branch.
- Progressive disclosure: hierarchy, sprawl, and co-location.
- Unambiguous instructions: completion criteria, leading words, negation, no-ops, and duplication.
- Consistency: no contradiction with other skills or shared docs the text names or that cover the
  same task. Search `home/private_dot_agents/skills/`, `~/.agents/skills/`, `~/.claude/skills/`,
  and `~/.claude/shared/`.
- Fidelity to the source decisions supplied in the prompt.

Severity is `critical` when an agent following the text does the wrong thing, or when the text
contradicts a source decision or another skill in a way that changes behavior. Severity is `major`
when an instruction makes runs diverge, such as an ambiguous step, missing completion criterion,
or missing step required by a source decision. Severity is `minor` for wording or pruning with no
behavior change.

Every finding cites its file and line and quotes the text it concerns. Do not report a finding
without a citation. Problems in unchanged text belong in `pre_existing`.

## Output

Write the report atomically: write `<report-path>.tmp`, then rename it to `<report-path>`. Use:

```json
{"findings": [{"id": "p<n>", "file": "...", "line": 1, "end_line": 1, "severity": "minor", "confidence": 90, "title": "...", "body": "...", "fix": "...", "verdict": ""}], "open_questions": [{"id": "q<n>", "file": "...", "line": 1, "end_line": 1, "severity": "minor", "confidence": 90, "title": "...", "body": "...", "fix": "", "verdict": ""}], "pre_existing": [], "immaterial": []}
```

Put questions for the author in `open_questions`.

Finish only after every changed file was read in full and every rubric item was applied.
