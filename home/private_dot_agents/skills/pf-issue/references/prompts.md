# Subagent prompts

Fill the angle-bracket slots. Every prompt names the repo root as an absolute path and the artifact directory files; agents trust the context file and verify only what their task needs.

## Current-state map (step 2, Explore agent, `model: "sonnet"`)

The map only locates and quotes code, so run it on Sonnet.

```
You are mapping the current state for issue <ID> in the repo at <ROOT> (a git worktree; git works). Read ~/.claude/artifacts/<ID>/context.md first — it holds the issue text and what is already verified; correct it only with evidence. The frame at its top bounds your scope: map what its required claims need, and report any other finding as one line under Out of scope. Budget: about 60 tool calls.

Map:
1. Consumers. Grep for <symbols>. For each consumer file, one line: surface it gates, and whether it gates read-only display or a write affordance.
2. Server truth. Read <server predicate files>. Which predicate does the server use for the same operation, and what does it return for each actor class: <classes>.
3. Contracts. Read the prose overview <contracts/<name>.md> and the built artifact <contracts/<name>/*.json> for each touched contract, and the source that feeds the artifact. Quote the governing entries with file:line and say whether prose and artifact agree.
4. Pins. Which existing tests, behaviour entries, or e2e specs pin the current behaviour.
5. History. `git log --follow` on <files>; `gh pr view <N> --json title,body` for the PRs that shaped them. Deliberate or accidental?

Report in English, under 1000 words, every fact with file:line, sections: Consumers / Server truth / Contracts / Pins / History / Corrections to the context file / Out of scope.
```

## Validator (step 4, one per validated candidate, general-purpose agent, `isolation: "worktree"`)

Launch with `isolation: "worktree"`: the validator edits and runs tests in its own copy, so the main tree stays clean (no lockfile churn, no scratch test files). The artifact files under `~/.claude/artifacts/` are outside the repo and stay readable.

```
You are an adversarial validator for a proposed solution. You work in your own git worktree of the repo at <ROOT>; edit, install, and run tests there freely. Read first:
- ~/.claude/artifacts/<ID>/context.md
- ~/.claude/artifacts/<ID>/candidates.md

Validate Candidate <N> ("<name>"). Facts in context.md that carry a file:line are verified; build on them. Spend your calls on what context.md does not cover and on what sets this candidate apart from the others in candidates.md. Break it by verifying each load-bearing claim against real code. Budget: about 30 tool calls in total. Spend them on the claims in the order listed; when the budget runs out, stop and mark every unchecked claim UNVERIFIED.

Claims to verify, each with the line the candidate relies on:
1. <claim> — <file:line>
2. ...

For each claim: trace every caller of the changed predicate, enumerate every actor class the rule admits and refuses, name the tests and behaviour entries that pin the current behaviour. Apply the change and run tests only when reading the code cannot decide the claim. State what a legitimate caller loses, or state none.

When you render a UI change, save a screenshot of each state you looked at to ~/.claude/artifacts/<ID>/candidate-<N>-<state>.png and list the paths in the report; the report embeds them, so the prototype is not rebuilt for pictures.

Also check: which contract artifacts move and the impact label per the classifier in scripts/contracts; which gate blocks and who can override it; whether an existing e2e capability or fixture breaks.

Report in English, under 900 words: verdict VIABLE / VIABLE WITH CHANGES / BROKEN; per-claim findings with file:line evidence; the list of changes the candidate needs beyond its spec; UNVERIFIED for any check you could not finish.
```

Resume message when a long validator dies: `Continue from check <N>. Wrap up with the evidence you already have; mark unfinished checks UNVERIFIED and write the final report now.`

## Flow-gap pass (step 4, when the change touches gating)

```
Ground everything in the repo at <ROOT>; read ~/.claude/artifacts/<ID>/context.md and candidates.md first. A gap is only a gap if the codebase does not already handle it.

Derive the user flows for Candidate <N> across viewer classes <(a)…(g)> and surfaces <list>, including mid-load states (role unresolved, grant pending, empty result, 403). For each cell: what the viewer sees, what the server returns, whether the candidate changes it.

Output under 900 words: ### User Flows; ### Gaps (Critical / Important / Minor, each naming the scenario, the viewer, the data state, file:line); ### Questions (what is at stake, your default assumption).
```
