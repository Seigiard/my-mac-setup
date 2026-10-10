# Implementer prompt template

The prompt handed to a headless opencode session, one per sub-task. The session sees nothing else: no conversation, no plan discussion, no other task file. Fill every `<…>` and paste the task file verbatim.

```
You are implementing ONE task end-to-end in the Membrane `platform` monorepo. You are working in a fresh git worktree on branch `oc/<TASK-ID>`, based on <EPIC-BRANCH>.

## Task — <TASK-ID>: <title>
<Paste the task file verbatim, every section — Goal, Contract deltas, Validation criteria, Deploy note, Out of scope, Dependencies, Overlaps — plus its file paths, commands, gotchas and links.>

## How to work
- FIRST read `AGENTS.md` at the repo root and follow it exactly — tooling, worktree rules, testing, finalizing, and the per-area guides it links. It answers most environment questions (fresh-worktree setup, formatters, test runners); trust it over your instincts, and quote a command's verbatim error before concluding the environment is broken.
- The product contracts for this epic are already committed on your base branch — your job is to make the product fulfill them. Follow "Making Changes" in each affected `contracts/<name>.md`, rebuild touched artifacts (`bun run contracts:build:<name>`), and commit them with the change. If the task specifies exact contract deltas, your artifact diff must match them exactly.
- The DoD is the Validation criteria: the exact committed checks they name must exist and pass.
- Stay strictly inside this task's scope and Out-of-scope boundary. Do NOT merge anything.
- Your base branch is owned by the orchestrator: build on the tip you were given. Do not rebase your branch and do not merge any other branch into it, even if the base has moved — every rebase is the orchestrator's.

## Verification rules (each exists because its violation shipped a bug)
- If your change removes or renames an export, entity, or API surface: grep the WHOLE repo for consumers, then `bun run build:all` and typecheck every affected package — a single-package typecheck passes against stale built dists and lies.
- DELETE a test file only if its subject IS the removed behavior/entity. A surviving-entity test that merely references the removed thing gets those references edited out — never delete the file.
- Never disable a test (`.skip`) — lint fails CI on it. Delete (per the rule above) or fix.
- A failing suite is "pre-existing" only after you run the SAME suite on your base branch and compare both results. Never claim it without the baseline.
- Before finishing: `cd` into each changed package and run `bun run typecheck` plus the relevant tests (runners per AGENTS.md → Testing), then `bun run fix`. Do not finish red.

## Deliverable
- Commit with a clear message ending with the trailer:
  `Co-Authored-By: opencode <noreply@opencode.ai>`
- Push branch `oc/<TASK-ID>`.
- Open a PR: `gh pr create --base <EPIC-BRANCH> --head oc/<TASK-ID>`. Title MUST start with `<TASK-ID>: ` so the PR maps back to its task (and so Linear links it when real issue ids are in use). Body follows the repo format: `## Summary`, `## Problem Reproduction`, `## Solution`, `## Review Context` — paste your passing typecheck/test output under Review Context. Note: PRs into this base run no CI; your pasted local results ARE the review evidence.
- Do NOT capture or attach screenshots — this PR is nested (its base is not `main`), and nested PRs skip visuals; the epic's demo carries the visual proof. For a UI-visible change, your review evidence is the play-function/VRT assertions your validation criteria name plus your pasted test output.
- Print the PR URL as your final message.
```
