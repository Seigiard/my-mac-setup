---
name: grill-design
description: Converge on a frontend look through rounds of prototypes and grilling verdicts. Use when the user wants to iterate on UI/visual taste against concrete variants, or a wayfinder prototype ticket names this skill.
---

Run a `/grilling` session with the `/prototype` skill, asking every question with prototypes instead of words. The round rules here are adapted from [variate](https://github.com/Nutlope/variate) (MIT).

## The brief

Before round one, name three things: the subject, the audience, and the design's primary job. Take them from the request, the repository, and what you know of the user, and confirm them in one message. Distinct designs come from the subject's world: its materials, its artefacts, its vocabulary. A dashboard for financial analysts and a toy for eight-year-olds share no answers. Done when the user has confirmed the brief.

## The design tree

A round asks one design question, and its five designs are the answers. Round one settles the overall design. Each verdict zooms one level down: the overall design, then component groups, then individual components. A settled level stays settled until the user reopens it. The session is done when the user has designed the entire feature down to its individual components.

## The round plan

The plan lives in the round's HTML as a `<script type="application/json" id="grill-round">` block. Naming the corners of the idea space before drawing keeps five designs from collapsing toward the same safe answer.

```json
{
  "question": "How much should the inbox say before you open a thread?",
  "designs": [
    { "id": "ledger", "name": "the ledger", "angle": "dense rows, type only", "cost": "nothing to scan by eye" },
    { "id": "cards", "name": "stacked cards", "angle": "one card per thread with a preview", "cost": "a third as many threads per screen" }
  ],
  "states": [{ "id": "full", "name": "full" }, { "id": "empty", "name": "empty" }]
}
```

- **question**: one line. Every design answers it.
- **name**: what you call the design in conversation, "the ledger" rather than "Option B". The picker shows it on the live chip.
- **angle**: the one thing this design changes. Two designs with the same angle are one idea under two names.
- **cost**: what the design gives up. Every real direction gives something up, and the user reads it in the picker while deciding.
- **states**: the meaningful states of the mock (an inbox: full vs empty), when it has them.

## Radically different

Designs differ in structure: layout, information hierarchy, primary affordance, visual device. Five tweaks of one card grid are wallpaper. When two designs come out alike, redraw one against an explicit constraint: "no card grid", "type only", "the composition is the background".

A design can also collapse toward your own default. Solve a similar brief in your head: an angle you would reach for on any similar product is a default, not an idea. Redraw it from the brief. When the brief itself asks for that look, the brief wins.

With no design system to inherit, settle a shared baseline first and write it as tokens: 4–6 named hex values, one or two clearly distinct type families with their roles, one spacing rhythm. Draw it from the brief and test it like an angle. The designs then differ in structure, and each verdict answers one question.

## Each round

1. **Plan.** Write the round plan. Done when every design has an angle no other design shares and no angle is a default.
2. **Build.** Put all five designs into one live mocked app: one standalone HTML file with its styles inline. Paste [assets/picker.js](assets/picker.js) whole into an inline `<script>` after the round plan. The picker writes the live choice to `<html data-design data-state>`: style each design under `[data-design="<id>"]`, and mark design- or state-specific markup with `data-for-design` or `data-for-state`. Compare the five against *Radically different*. Done when every design and every state renders without a console error, at desktop width and at 390px.
3. **Publish.** Publish the file with the Artifact tool. Every later round updates the same file path, so the URL stays the same.
4. **Ask.** Say what each design tries, by number and name, in the user's words. Name the one you would keep, why, and what it costs: a recommendation without its cost reads as a sales pitch. Ask one question. Done when the user has given a verdict.
5. **Apply the verdict**, then open the next round one level further down the design tree.

## Applying a verdict

- **The round narrows.** The kept design becomes the base of the next round, and rejected directions leave the picker.
- **A rejected direction stays dead.** Offering it again two rounds later as a fresh idea reads as not listening. It returns only when the user asks for it.
- **A merge is the best feedback.** "2's layout with 4's header" is the next design: draw it. Lift each part whole from exactly one donor and name the donors in its `angle`. An average of two directions is the middle neither wanted.
- **Small edits are edits.** A word or a spacing value changes in place. A round is for a question with more than one defensible answer.
- **Silence means a weak question.** Ask a sharper one.

[references/craft.md](references/craft.md) holds the steers (calmer, bolder, airier, denser, playful), the content, structure, type, and motion rules. Read it when the user steers, when you write mock copy, when you build a design, or when anything in a design moves.
