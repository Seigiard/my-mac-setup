---
name: pf-issue
description: Audit a tracker issue against the product contracts and the code, treating the issue as a hypothesis, then deliver validated solution options as a show-me markdown report. Defect entry to the /pf-research → /pf-spec → /pf-build cycle: hands off to /pf-spec when the chosen fix changes a contract, to /to-spec or /implement otherwise. Use when the user says "pf-issue <issue>", asks to study or explain an issue relative to code and contracts, or asks in Russian ("изучи <issue> относительно кода и контрактов", "исследуй <issue>, посмотри код и контракты", "в чём проблема и варианты решения").
argument-hint: "<issue URL or ID>"
---

# /pf-issue — audit a tracker issue against contracts and code

The defect entry to the pf cycle: `/pf-research` starts from a product change, `/pf-issue` starts from a reported issue. Both end at the same fork — `/pf-spec` when the fix changes a contract, `/to-spec` or `/implement` when it stays inside the contracts. Shared mechanics (artifact storage, Linear as opt-in, naming on public surfaces, missing-prior analysis): read `~/.claude/shared/pf-cycle.md` first. This step changes nothing in the repo and writes nothing to the tracker.

Authority runs contracts → code → issue. Past audits confirmed the issue's complaint every time and found it incomplete every time: a stale number, a second symmetric leak, a wrong mechanism, a premise the contract itself contradicts. The audit's value is what the issue did not say and the fix direction it got wrong.

The report is written in the user's language. Subagent prompts are English. The artifact directory `~/.claude/artifacts/<ISSUE-ID>/` carries the state between steps — `issue.md` for the fetched issue, `context.md` for verified facts, `candidates.md` for the options — and subagents read those files instead of re-researching.

## 1. Anchor

- Resolve the repo root once and use absolute paths in every command (a drifting cwd cost three sessions their first greps).
- `git fetch origin`; record the commit you analyse and whether HEAD is behind `origin/main`. A sibling ticket may have just landed on the same surface.
- Fetch the whole issue into `~/.claude/artifacts/<ISSUE-ID>/issue-source.md` — never through `| head`. Read the acceptance criteria: they may demand something the code cannot deliver.
- Search the tracker for siblings sharing the screenshot, the surface, or the bet, so you know which layer this ticket owns.
- Locate the contracts: the repo's `AGENTS.md` / `CLAUDE.md` names them. For `platform`, `references/platform.md` caches the layout and the tracker commands.

Done when commit, full issue, sibling list, and contract locations are written to `context.md` in the artifact directory.

## 2. Map the current state

Read the code path yourself; delegate a wide surface to one Explore agent with the map prompt in `references/prompts.md`. Gather into the context file, every fact with `file:line`:

- **Measure, never trust.** Counts, sets, and "N places" come from a throwaway script or a grep you ran. When the issue says "not verified", verify the primary evidence: rows in the dev database, a live request, the dev stack viewed as the affected role.
- **Contracts, both halves.** For every contract the surface touches read the prose overview *and* the built artifact, then the source that feeds the artifact (test titles, command declaration fields, catalog entries). Quote the governing line and say which half it came from. Also read the contract's process rules ("Making Changes", gates, override policy): a contract can forbid a PR shape, not only a behaviour.
- **History.** `git log --follow` on the predicate or file and the PR bodies that explain why. Deliberate decision or accidental parallel evolution is a finding.
- **Pins.** Which existing test, behaviour entry, or e2e capability pins the current behaviour.

Classify each symptom the issue names: data leak, wording leak, declared behaviour, stale contract prose, invalid fixture, not reproduced. Give every claim in the issue a verdict — confirmed, narrowed, refuted — with the evidence line.

Two outcomes need their own sentence in the report: the contract *intends* the behaviour the issue calls a bug, so the fix is a contract change that needs the owner's confirmation; or the contract prose contradicts the artifact or the code, so the stale prose is in scope.

Done when every issue claim carries a verdict and the context file quotes the governing contract lines.

## 3. Draft options

Two to four options, composites allowed. Each option answers, in one line each:

- mechanism, and the precedent in the repo it copies
- what it fixes and what it leaves broken
- who loses a capability: enumerate the actor classes the rule admits and refuses
- whether the boundary it moves is enforcement or presentation
- which pinned test or behaviour entry breaks
- which contract artifacts move, the impact label, and the classifier line that decides it
- which gate blocks merge and who can override it
- what stays unknown

Numbers come from evidence in the repo or are marked unknown. An estimate you cannot source is left out.

Done when every option has all eight lines and a recommendation is written with its reason.

## 4. Validate the top two

Launch one validator per candidate in parallel with the validator prompt in `references/prompts.md`. The prompt lists the candidate's load-bearing claims with `file:line` and demands enumeration and execution — trace every caller, list every actor class, apply the change and run the tests where feasible — and a three-valued verdict: VIABLE, VIABLE WITH CHANGES, BROKEN, with UNVERIFIED on anything unfinished. When the change touches gating, add the flow-gap prompt: viewer classes × surfaces × loading states.

Re-verify every finding against source before accepting it; reject with a reason. A BROKEN verdict sends the option back to step 3 with the finding recorded, and the loop runs until two candidates hold or you can honestly say only one does. A claim you cannot verify locally gets a research agent for the workaround before it is reported as open.

Done when both candidates carry a verdict you have re-verified and every required change is listed.

## 5. Report

Load the `show-me` skill and write `~/.claude/artifacts/<ISSUE-ID>/issue.md` with the shape in `references/report.md`; then `open` it and give a chat summary under fifteen lines. Verdict first, plain words, every term expanded, no labels coined in this session. Close with the decisions you made yourself, the one decision left to the user, and the handoff line the user can type:

- `/pf-spec <ISSUE-ID>` when the chosen option changes a contract — the audit is the research narrative `/pf-spec` reads, and the contract owner's confirmation is part of that step.
- When the fix stays inside the contracts: `/to-spec` in this same session when it needs more than one session — it synthesizes the conversation, and `/to-tickets` then `/implement` per ticket follow — or `/implement` right here when it fits one session. `/to-spec` and `/to-tickets` publish to the tracker, so they run only when the user types them.
- Follow-ups stay as ticket-ready text in the report until the user asks to file them.

A menu widget for that decision gets declined; write prose.
