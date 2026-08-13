---
name: pf-research
description: Research a product change — gather everything relevant (code, contracts, the live product, Linear, prod) and produce a research narrative of what is and what should become, which the user confirms before /pf-spec writes it into the product contracts. First step of the /pf-research → /pf-spec → /pf-build cycle. Use when the user says "pf-research <topic/epic>", brings an idea/problem/opportunity to shape, or asks to plan a product change — planning now starts here.
argument-hint: "<topic-or-epic>"
---

# /pf-research — gather and narrate a product change

Research a product change: gather everything relevant — code, contracts, the live product, Linear, prod — and produce a **research narrative**: the story of what is and what should become, which the user confirms before `/pf-spec` writes it into the product contracts. First step of the `/pf-research` → `/pf-spec` → `/pf-build` cycle (shared mechanics: read `~/.claude/pf-cycle.md` first).

## What the research narrative is

A narrative, not a spec and not a plan: the story of the current reality and the envisioned change, told in product terms, precise enough that `/pf-spec` can turn it into contract deltas without guessing intent. It changes nothing — no contract edits, no sub-issue slicing, no code, no PRs. Its entire job is to get the theory in the user's head and the theory on the page to be the same theory.

## Gather

Gather wide, then keep only what shapes the narrative:

- **The contracts** — the committed artifacts (entity manifest, commands, ux manifest, AI surfaces) are the authoritative map of what the product *is*; read the relevant slices before trusting memory of them.
- **The live product** — run it and look: the current state of every surface the change touches, captured as real screenshots (pf-cycle → screenshot mechanics). What users see today is the "before" half of the story.
- **The code** — enough of the affected areas (via their `README.md` guides) to know what's load-bearing, what's cheap, and what's expensive; the narrative should not envision the impossible without saying so.
- **History** — Linear (prior issues, the epic if one exists), memory topics, git history of the touched surfaces: what was tried, decided, or deliberately avoided.
- **Prod** — when the change concerns real usage, ground it in data (prod DB read-only access, logs, task inspection per repo `CLAUDE.md`).

## The narrative

Structure the research narrative HTML (pf-cycle → artifact storage + HTML mechanics; visible text follows pf-cycle → Naming on public surfaces) in product order:

1. **What is** — the current state, narrated over real screenshots of today's product; the entities/commands/pages involved as they exist now.
2. **The gap** — why change: the user need, the broken seam, the opportunity; grounded in what Gather found, not asserted.
3. **What should become** — the envisioned change as a user-experienced story: what the user will see and do, flow by flow. Vision-state imagery may be sketches/mockups here (clearly badged as such) — `/pf-spec` replaces them with real story renders.
4. **The surfaces it will touch** — a forecast of which contracts (IA / API / UX / AI) will need deltas and roughly what kind, so the user sees the blast radius. A forecast, not the deltas themselves.
5. **Decisions and open questions** — every choice the narrative makes that the user could reasonably make differently, stated as a decision with the chosen answer; genuinely open questions listed for the user to answer at review.
6. **Risks and constraints** — migrations, breaking-label exposure, deploy shape, anything expensive the vision implies.

## Present and iterate

Present the research narrative in chat: the published artifact link plus a tight summary of the vision and the open questions. Fold feedback in and republish until the user confirms the narrative matches the theory in their head — run the **missing-prior analysis** (pf-cycle) on every round: feedback that reveals a missing prior updates repo context, not just the narrative.

**Pure research — no Linear writes.** This step changes nothing anywhere: no epic, no issues, no comments. If an epic already exists, read it as history and store artifacts under its id; otherwise store them under a short kebab topic slug (`~/.claude/artifacts/<topic-slug>/`). The whole cycle works off this directory — Linear stays untouched unless the user explicitly asks for it (pf-cycle → Linear is opt-in).

**Hand off.** On confirmation: the research narrative is approved. The user runs `/pf-spec <epic-or-topic>`.
