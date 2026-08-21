---
title: "Decide whether se-review-and-work and se-simplify should stay model-invoked"
short_description: "Decide whether se-review-and-work and se-simplify should stay model-invoked"
type: "idea"
category: "testing-ci"
tags: ["testing-ci","idea"]
date: "2026-08-15"
status: "wontfix"
priority: "low"
closed: "2026-08-15"
---

## Why this exists

Every skill with a frontmatter `description` pays context load on every turn of every session, because the description is always loaded so the model can discover the skill on its own. A skill set to `disable-model-invocation: true` costs nothing: only the human typing its name can start it.

Two skills in `home/private_dot_claude/skills/` looked like candidates for user-invocation, and the switch changes behaviour, so it was raised rather than applied during the 2026-08-15 writing pass:

- `se-review-and-work/SKILL.md` — no other skill invokes it. Its own body states the user picks between it and `se-work` by command name, so it is a hand-typed entry by design.
- `se-simplify/SKILL.md` — the pipeline runs simplify as the workflow `se-simplify.tsx`, not by invoking this skill, so nothing but the human reaches it. Its standalone path is rare because it demands an explicit `validate-cmd`.

Not a candidate: `se-doc-review` must stay model-invoked — `se-plan/SKILL.md` invokes it through the Skill tool with `mode:headless <plan-path>`, and a user-invoked skill can be invoked by nothing but the human.

## Resolution

Both stay model-invoked. The saving the proposal rested on had already been taken another way in the same pass.

Measured after the description rewrite: the two descriptions are 35 words each, 231 and 227 characters — roughly 115 tokens combined. The proposal was formed while the `se-*` family carried ~396 words of description, including a hint tail (`plus secret-scan gates, approval pauses, and a cost summary`) repeated verbatim in both twins. That tail was cut in the same pass and the family now stands at 262 words, so the context-load argument no longer buys anything worth the behaviour it costs.

Nothing invokes either skill through the Skill tool, so the switch was mechanically available — but availability is permission, not reason. What it would cost:

- `se-review-and-work` — when the user says "запусти пайплайн" on a plan that was never plan-reviewed, the correct action is to route to this skill. User-invoked, the agent can name it (se-work's description points at it) but cannot start it, and must ask the user to type the command.
- `se-simplify` — the only value of its description is letting the agent propose a tidy pass unprompted. Disabled, the 35 words are not saved so much as traded for a lost capability.

Cognitive load is not a cost to minimise for its own sake; it is the price of human agency, and it is worth paying where human judgement matters. Here judgement is needed on "should this expensive run start", which pre-launch confirmation already covers, not on "does this skill exist".

**The general rule this yields:** turn off model-invocation when a description exists only to distinguish a skill from its neighbour, and only after everything that is not a trigger has already been cut from it. Measure the description first — the cut is usually the whole win.
