---
name: pf-spec
description: Write an approved research narrative into the product contracts — author the contract deltas, open the epic PR (kept open, /pf-build builds into it), and iterate with the user until the contract spec matches the theory in their head. Second step of the /pf-research → /pf-spec → /pf-build cycle. Use when the user says "pf-spec <epic-or-topic>" or approves a research narrative; a small, well-understood change may be spec'd directly from the user's instruction with no formal research step.
argument-hint: "<epic-or-topic>"
---

# /pf-spec — write the research into the product contracts

Write the approved research narrative into the product contracts: author the contract deltas, open the **epic PR** (kept open — `/pf-build` builds into it), and iterate with the user until the contract spec matches the theory in their head, analyzing every feedback round for missing priors. Second step of the `/pf-research` → `/pf-spec` → `/pf-build` cycle (shared mechanics: read `~/.claude/pf-cycle.md` first).

## What the contract spec is

The product change expressed as contract deltas: the entities, commands, pages/components, and agent surfaces that will exist once the change ships. The contracts are the review surface — the user reviews what the product will become, not how it will be coded. Two artifacts: the **epic PR** (real contract changes) and the **spec narrative** (generated from the artifacts of those changes: the purpose of the change and its results).

## Step 1 — Author the contract deltas

**Anchor in the artifact directory — no Linear writes by default.** The research step's directory (`~/.claude/artifacts/<topic-slug>/`, or `<EPIC-ID>/` when an epic already exists) is the cycle's tracker; keep working off it. Create a Linear epic only when the user explicitly asks for Linear tracking (title = the change, description = the research narrative's model summary + artifact link; Linear is a public surface — pf-cycle → Naming on public surfaces), then rename the artifact directory from its topic slug to the epic id. Never sub-issues — slicing is `/pf-build`'s.

Read the research narrative's canonical source (`~/.claude/artifacts/<id>/research.md`). Route the change through the contract table in `CLAUDE.md` (IA / API / UX / AI / Code Quality) and follow each affected overview's "Making Changes". Write the actual source declarations and build the artifacts (`bun run contracts:build:<name>`):

- **UX** — Storybook stories for every new or changed component/page, plus route/manifest declarations. The stories are the design spec `/pf-build` implements against — get states, copy, and layout decided here, not during implementation. Two recurring gotchas: story-only pages must **not** declare `parameters.uxRoute` (the ux-manifest build fails on routes that don't exist yet — use derived titles until wired), and any story-only ALLOWLIST entries you add must be removed by the implementation sub-task that wires the page — record that handoff as a deferred delta (below).
- **IA** — entity/schema declarations, so the entity-manifest delta shows exactly the new or changed entities, fields, and relations.
- **API** — command declarations: names, input/output schemas, exposed surfaces (HTTP / MCP / agent tools / UI).
- **AI** — tool mounts, context changes, and benchmark scenarios wherever agent behavior changes. A benchmark criterion must specify what the validator **rejects**, not just what it accepts — name the wrong-but-plausible shapes that must fail; a validator asserting mere presence certifies breakage.

Constraints:

- **The epic PR must be green and shippable at every iteration** — `bun run contracts:check` passes; declarations may be inert (a story rendering mock data, an entity nothing writes yet) but must never break a live surface. Its base is `main`, so real CI runs on it throughout.
- **Not every delta can land ahead of implementation.** When a contract change needs working code the PR can't carry (a gate would fail), don't stub or fake it — record it as a **deferred delta** in the spec narrative: the artifact file and the precise entries/fields/values expected in its diff. `/pf-build` carries each deferred delta into the sub-task that implements it and verifies the diff at review.
- Impact labels (`API: Breaking`, `IA: Breaking`, …) are computed from the artifact diff on the PR. The user's iterative approval of the contract spec is the owner review those labels call for; overrides are human-only — the user applies them, never you.

## Step 2 — Open the epic PR (and keep it open)

One PR, base `main`, branch named for the change. **Name the PR for what it will contain when it merges, not what it holds today.** This PR stays open and becomes the single big PR once `/pf-build` merges the implementation into its branch — so the title is the epic's product change itself (e.g. "PRD-1234: Deliverable views"), never a snapshot of its current contents like "Contract spec for deliverable views" (pf-cycle → Naming on public surfaces). Repo PR-body format: the Summary likewise describes the full change, noting that the contract spec lands first and the implementation follows into this same PR; the spec narrative's artifact link goes under Review Context. **Do not merge it** — unlike the old planning-PR flow, it stays open and becomes the single big PR after `/pf-build` merges implementation into its branch; the user performs the one final merge to main. Attach the PR to the Linear epic only if one exists — never create one for this.

## Step 3 — Generate the narrative from the artifacts

Build the spec narrative HTML (pf-cycle → artifact storage + HTML mechanics; visible text follows pf-cycle → Naming on public surfaces — the page presents itself as the epic's contract spec) from what the PR actually changed — never from intentions:

- **Purpose** — what the change is for, carried over from the research narrative in a paragraph.
- **The results** — per contract: the rendered diff (pf-cycle → rendering contract diffs) with its computed impact label, and for UX every new/changed story captured as a real render. Product-order flow sections, exactly as the change will be experienced.
- **Deferred deltas** — the explicit list `/pf-build` must produce, each with its expected artifact diff.
- **Iteration ledger** — dated rounds: feedback → classification (missing-prior analysis) → what changed and where any prior landed.

## Step 4 — Frontier review pass (opencode)

Before presenting each substantive revision to the user, run the contract spec past opencode on the **frontier tier** and fold in what survives your judgement. This is the deliberate, user-mandated exception to the terra-only opencode rule (implementation dispatches stay on `openai/gpt-5.6-terra`): frontier is allowed for exactly this review, never for implementation dispatches.

```bash
opencode run --dir <epic worktree> \
  -m openai/gpt-5.6-sol \
  -f <screenshot1.png> -f <screenshot2.png> ... \
  "<review prompt>"
```

opencode has no hard read-only mode in a headless run — open the review prompt with an explicit instruction: review only, do not edit, write, create, or delete anything; and run **without** `--auto`, so an attempted edit dies on the permission gate instead of landing. If the frontier slug has rotated off `openai/gpt-5.6-sol`, use the current frontier model and note the new slug in your report. Hand it exactly what the user gets, each named with its path: the narrative HTML (plus **every screenshot as a real PNG via repeated `-f` flags** — inlined base64 is opaque to a model), the research narrative source, the branch name with instructions to read the actual diff (`git diff origin/main...<branch>`). Ask for numbered findings with severity, judged as a *contract* review: wrong/missing/inconsistent deltas; decisions left to implementer discretion; deferred deltas that could land now; incoherence between the narrative and the diff; deploy risks the spec doesn't carry. Tell it explicitly to challenge decisions, not restyle prose. Triage open-mindedly, but don't be a pushover — record accept/reject with reasons, and include a short "frontier review" section when presenting: each finding, accepted (and where it landed) or rejected (and why).

## Step 5 — Iterate with the user

Present in chat: the PR link, one-line summary per contract delta, impact labels, and the narrative artifact link. This loop is the point of the command — expect several rounds. On every round run the **missing-prior analysis** (pf-cycle): feedback caused by an under-specified spec is simply applied; feedback caused by a missing prior *also* updates the repository context so the next spec doesn't repeat it. Rebuild artifacts, regenerate the narrative, republish, update the ledger, keep the PR green.

**Hand off.** When the user confirms the contract spec matches their theory: record the PR + narrative links in the artifact directory (and on the epic, when a Linear one exists), and the user runs `/pf-build <epic-or-topic>`.
