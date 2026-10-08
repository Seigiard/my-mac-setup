---
name: pf-research
description: Research a product change and produce a research narrative of what is and what should become, for the user to confirm. First step of the /pf-research → /pf-spec → /pf-build cycle. Use when the user says "pf-research <topic-or-epic>", brings an idea or problem to shape, or asks to plan a product change — planning starts here.
argument-hint: "<topic-or-epic>"
---

# /pf-research — gather and narrate a product change

Research a product change: frame the decisions it needs, gather the evidence for them — from code, contracts, the live product, Linear, prod — and produce a **research narrative**: the story of what is and what should become, which the user confirms before `/pf-spec` writes it into the product contracts. First step of the `/pf-research` → `/pf-spec` → `/pf-build` cycle (shared mechanics: read `~/.claude/shared/pf-cycle.md` first; for screenshots and narrative pages also `~/.claude/shared/pf-cycle-narratives.md`).

## What the research narrative is

A narrative, not a spec and not a plan: the story of the current reality and the envisioned change, told in product terms, precise enough that `/pf-spec` can turn it into contract deltas without guessing intent. It changes nothing — no contract edits, no sub-issue slicing, no code, no PRs. Its entire job is to get the theory in the user's head and the theory on the page to be the same theory.

## Frame

Orient on the topic or epic until you can name the surfaces it touches, then copy the research template (pf-cycle-narratives → Narrative HTML mechanics) to `~/.claude/artifacts/<id>/research.html` and fill its Frame block (pf-cycle → The frame). Read the governing contract lines before any code. Done when the frame states the question, quotes the governing rule, lists the required claims, and says when the gather is done.

## Gather

Gather what the frame requires. Gathering is done when the frame's done condition holds, every surface the frame names has a captured "before" screenshot, every contract slice it names has been read rather than recalled, and every question the gather raised is written down as answered or open.

Split the gather into lanes so your own context holds summaries, not file dumps. Run pf-cycle → Environment preflight for the surfaces and prod access the frame names, then dispatch the contracts, code, history, and prod lanes in one message as parallel subagents (`model: "sonnet"`; Explore for contracts and history, general-purpose for code and prod, where the lane must judge cost or run queries). Each prompt carries the frame, the surfaces, and that lane's bullet below as its brief, bounded per pf-cycle → Dispatching subagents. Read a narrow lane yourself, and skip a lane the change does not reach. Each lane returns a short summary with every fact cited (`file:line`, issue id, query); write each to `~/.claude/artifacts/<id>/gather/<lane>.md`. While they run, you own the live product: the "before" screenshots and nothing else. Then open the cited lines behind every fact the narrative states about the contracts or the code; a summary tells you where to read, and the reading is yours. Batch independent reads into one turn.

- **The contracts** — the committed artifacts (entity manifest, commands, ux manifest, AI surfaces) are the authoritative map of what the product *is*; read the relevant slices before trusting memory of them.
- **The live product** — run it and look: the current state of every surface the change touches, captured as real screenshots (pf-cycle-narratives → screenshot mechanics). What users see today is the "before" half of the story.
- **The code** — enough of the affected areas (via their `README.md` guides) to know what's load-bearing, what's cheap, and what's expensive; the narrative should not envision the impossible without saying so.
- **History** — Linear (prior issues, the epic if one exists), memory topics, git history of the touched surfaces: what was tried, decided, or deliberately avoided.
- **Prod** — when the change concerns real usage, ground it in data (prod DB read-only access, logs, task inspection per repo `CLAUDE.md`).

## The narrative

Fill the research template's sections in `research.html` (pf-cycle → artifact storage + Language; pf-cycle-narratives → HTML mechanics + Publishing; visible text follows pf-cycle → Naming on public surfaces), in product order:

1. **What is** — the current state, narrated over real screenshots of today's product; the entities/commands/pages involved as they exist now.
2. **The gap** — why change: the user need, the broken seam, the opportunity; grounded in what Gather found, not asserted.
3. **What should become** — the envisioned change as a user-experienced story: what the user will see and do, flow by flow. Vision-state imagery may be sketch frames here (pf-cycle-narratives → Screenshot mechanics) — `/pf-spec` replaces them with real story renders.
4. **The surfaces it will touch** — a forecast of which contracts (IA / API / UX / AI) will need deltas and roughly what kind, so the user sees the blast radius. A forecast, not the deltas themselves.
5. **Decisions and open questions** — every choice the narrative makes that the user could reasonably make differently, stated as a decision with the chosen answer; genuinely open questions listed for the user to answer at review; neighbouring findings the frame left out, one line each.
6. **Risks and constraints** — migrations, breaking-label exposure, deploy shape, anything expensive the vision implies.

## Present and iterate

Present the research narrative in chat: the published artifact link plus a tight summary of the vision and the open questions. When the user starts answering the open questions, walk them one per turn, each as a self-contained decision brief: the question in plain words with no session labels, the options with their consequences, your recommendation. Fold each round into `research.html`, rebuild it with `assemble.py`, and republish until the user confirms the narrative matches the theory in their head — run the **missing-prior analysis** (pf-cycle) on every round: feedback that reveals a missing prior updates repo context, not just the narrative.

**Pure research — no Linear writes.** This step changes nothing anywhere: no epic, no issues, no comments. If an epic already exists, read it as history and store artifacts under its id; otherwise store them under a short kebab topic slug (`~/.claude/artifacts/<topic-slug>/`). The whole cycle works off this directory — Linear stays untouched unless the user explicitly asks for it (pf-cycle → Linear is opt-in).

**Hand off.** On confirmation, `~/.claude/artifacts/<id>/research.html` carries every approved change, and it is what `/pf-spec` reads. The state of the cycle lives in that directory, so the next step starts from a clean context: close with the line the user types after `/clear` — `/pf-spec <epic-or-topic>`.
