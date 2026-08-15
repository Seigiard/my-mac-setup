# Decision brief

The shape of every request for a user decision produced by the se-pipeline skills — a paused gate, an open finding in a review envelope, a plan ambiguity. The reader has not followed the run: they have not read the log, the envelope, or the plan, and they do not know the vocabulary the run used internally.

> **Why this file exists, given that the writing-style rules already define the brief.** Those rules are always loaded, but session analysis showed they stop being followed once the chain gets long and the context fills. This file is the re-anchor at the point of use, reached by a pointer exactly when a decision is being asked. It is not a duplication defect — do not delete it as one. The writing-style output style (`home/.chezmoitemplates/writing-style.md` → "Asking for a decision") remains the source of the rule; what follows adds the run-specific option semantics it cannot carry.

Four parts, in this order:

1. **The thing** — what it is in plain words. No run IDs, stage names, persona labels, envelope keys, or plan unit IDs as the sole identifier; name the subject itself, and put an ID in parentheses at most.
2. **The decision** — what exactly is being decided, and what it blocks.
3. **Options** — two or three, each with its consequence stated. For a gate: approve = one more paid attempt of the stage, deny = stop with a report, abort = kill the run.
4. **Recommendation** — one option, and why.

Rules that hold everywhere the brief is used:

- One decision per turn. Ask the next only after the user answers the current one.
- A report turn carries no questions; deliver the report, end the turn, then ask.
- When asking through AskUserQuestion, each option description carries its own consequence — the user must be able to choose without opening the log.
- Quote the failure verbatim rather than paraphrasing it. A paraphrased gate reason is the one thing the user cannot check.
