---
name: inscribe
description: Inscribe an approved divination into the product contracts — author the contract deltas, open the inscription PR (kept open, /cast builds into it), and iterate with the user until the inscription matches the theory in their head. Second spell of the /divine → /inscribe → /cast cycle. Use when the user says "inscribe <epic-or-topic>" or approves a divination; a small, well-understood change may be inscribed directly from the user's instruction with no formal divination.
argument-hint: "<epic-or-topic>"
---

# /inscribe — write the divination into the product contracts

Inscribe an approved divination into the grimoire of the product — the product contracts: author the contract deltas, open the **inscription PR** (kept open — `/cast` builds into it), and iterate with the user until the inscription matches the theory in their head, analyzing every feedback round for missing priors. Second spell of the `/divine` → `/inscribe` → `/cast` cycle (shared mechanics: read `~/.claude/grimoire.md` first).

## What an inscription is

The product change expressed as contract deltas: the entities, commands, pages/components, and agent surfaces that will exist once the spell is cast. The contracts are the review surface — the user reviews what the product will become, not how it will be coded. Two artifacts: the **inscription PR** (real contract changes) and the **inscription narrative** (generated from the artifacts of those changes: the purpose of the spell and its results).

## Step 1 — Author the contract deltas

**Anchor in the artifact directory — no Linear writes by default.** The divination's directory (`~/.claude/artifacts/<topic-slug>/`, or `<EPIC-ID>/` when an epic already exists) is the cycle's tracker; keep working off it. Create a Linear epic only when the user explicitly asks for Linear tracking (title = the change, description = the divination's model summary + artifact link; both in plain terms per grimoire → Public wording — Linear is a public surface), then rename the artifact directory from its topic slug to the epic id. Never sub-issues — slicing is `/cast`'s.

Read the divination's canonical source (`~/.claude/artifacts/<id>/divination.md`). Route the change through the contract table in `CLAUDE.md` (IA / API / UX / AI / Code Quality) and follow each affected overview's "Making Changes". Write the actual source declarations and build the artifacts (`bun run contracts:build:<name>`):

- **UX** — Storybook stories for every new or changed component/page, plus route/manifest declarations. The stories are the design spec `/cast` implements against — get states, copy, and layout decided here, not during implementation. Two recurring gotchas: story-only pages must **not** declare `parameters.uxRoute` (the ux-manifest build fails on routes that don't exist yet — use derived titles until wired), and any story-only ALLOWLIST entries you add must be removed by the casting sub-issue that wires the page — record that handoff as a deferred delta (below).
- **IA** — entity/schema declarations, so the entity-manifest delta shows exactly the new or changed entities, fields, and relations.
- **API** — command declarations: names, input/output schemas, exposed surfaces (HTTP / MCP / agent tools / UI).
- **AI** — tool mounts, context changes, and benchmark scenarios wherever agent behavior changes. A benchmark criterion must specify what the validator **rejects**, not just what it accepts — name the wrong-but-plausible shapes that must fail; a validator asserting mere presence certifies breakage.

Constraints:

- **The inscription PR must be green and shippable at every iteration** — `bun run contracts:check` passes; declarations may be inert (a story rendering mock data, an entity nothing writes yet) but must never break a live surface. Its base is `main`, so real CI runs on it throughout.
- **Not every delta can land ahead of implementation.** When a contract change needs working code the PR can't carry (a gate would fail), don't stub or fake it — record it as a **deferred delta** in the inscription narrative: the artifact file and the precise entries/fields/values expected in its diff. `/cast` carries each deferred delta into the sub-issue that implements it and verifies the diff at review.
- Impact labels (`API: Breaking`, `IA: Breaking`, …) are computed from the artifact diff on the PR. The user's iterative approval of the inscription is the owner review those labels call for; overrides are human-only — the user applies them, never you.

## Step 2 — Open the inscription PR (and keep it open)

One PR, base `main`, branch named for the change. **Name the PR for what it will contain when it merges, not what it holds today.** This PR stays open and becomes the single big PR once `/cast` merges the implementation into its branch — so the title is the epic's product change itself (e.g. "PRD-1234: Deliverable views"), never a snapshot of its current contents like "Contract spec for deliverable views", and never "inscription" or "spell" (plain terms per grimoire → Public wording). Repo PR-body format: the Summary likewise describes the full change, noting that the contract spec lands first and the implementation follows into this same PR; the inscription narrative's artifact link goes under Review Context. **Do not merge it** — unlike the old planning-PR flow, it stays open and becomes the single big PR after `/cast` merges implementation into its branch; the user performs the one final merge to main. Attach the PR to the Linear epic only if one exists — never create one for this.

## Step 3 — Generate the narrative from the artifacts

Build the inscription narrative HTML (grimoire → artifact storage + HTML mechanics; visible text follows grimoire → Public wording — the page presents itself as the epic's contract spec) from what the PR actually changed — never from intentions:

- **Purpose** — what the change is for, carried over from the divination in a paragraph.
- **The results** — per contract: the rendered diff (grimoire → rendering contract diffs) with its computed impact label, and for UX every new/changed story captured as a real render. Product-order flow sections, exactly as the change will be experienced.
- **Deferred deltas** — the explicit list `/cast` must produce, each with its expected artifact diff.
- **Iteration ledger** — dated rounds: feedback → classification (rite of priors) → what changed and where any prior landed.

## Step 4 — Frontier review pass (Codex)

Before presenting each substantive revision to the user, run the inscription past Codex on the **frontier tier** and fold in what survives your judgement. This is the deliberate, user-mandated exception to the terra-only Codex rule: frontier is allowed for exactly this review, never for implementation dispatches.

```bash
codex exec -C <inscription worktree> -s read-only \
  -m gpt-5.6-sol \
  -i <screenshot1.png> -i <screenshot2.png> ... \
  "<review prompt>" < /dev/null
```

Always redirect stdin or Codex blocks on "Reading additional input…". If the frontier slug has rotated off `gpt-5.6-sol`, use the current frontier model and note the new slug in your report. Hand it exactly what the user gets, each named with its path: the narrative HTML (plus **every screenshot as a real PNG via repeated `-i` flags** — inlined base64 is opaque to a model), the divination source, the branch name with instructions to read the actual diff (`git diff origin/main...<branch>`). Ask for numbered findings with severity, judged as a *contract* review: wrong/missing/inconsistent deltas; decisions left to implementer discretion; deferred deltas that could land now; incoherence between the narrative and the diff; deploy risks the inscription doesn't carry. Tell it explicitly to challenge decisions, not restyle prose. Triage open-mindedly, but don't be a pushover — record accept/reject with reasons, and include a short "Codex frontier review" section when presenting: each finding, accepted (and where it landed) or rejected (and why).

## Step 5 — Iterate with the user

Present in chat: the PR link, one-line summary per contract delta, impact labels, and the narrative artifact link. This loop is the point of the command — expect several rounds. On every round run the **rite of priors** (grimoire): feedback caused by an under-specified spell is simply applied; feedback caused by a missing prior *also* updates the repository context so the next inscription doesn't repeat it. Rebuild artifacts, regenerate the narrative, republish, update the ledger, keep the PR green.

**Hand off.** When the user confirms the inscription matches their theory: record the PR + narrative links in the artifact directory (and on the epic, when a Linear one exists), and the user runs `/cast <epic-or-topic>`.
