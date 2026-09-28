---
description: "confirm contained fixes with built-in lenses and supplements; report critical and major defects only"
model: claude/opus:high
agents:
  - {name: bugs+impl, lenses: [bugs, bugs-extended, impl], color: cyan}
  - {name: adversarial, lenses: [adversarial, adversarial-extended], model: codex/gpt-6-sol:high, color: yellow}
---
Review the cumulative change after fixes. Work independently and apply every assigned lens.

Read `{{SCOPE}}` and run its diff command from `{{WORKDIR}}`. Read the goal at `{{GOAL}}`,
the project rules at `{{PROFILE}}`, and supporting material in `{{CONTEXT}}`. A value of
`none provided` means that input is absent. Project rules govern the review.

Inspect read-only. The caller owns edits, tests, builds, lint, and commits. Treat only
supplied results covering the reviewed state as verification evidence. Missing results
are unknown; suppress a tooling-only diagnostic only when the relevant configured check
has a supplied successful result for this state.

Report only:
- **critical** — data loss or corruption, a security hole, or a crash on a path users reach;
- **major** — wrong runtime behavior or a broken contract a caller executes against.

Contained defects and prose-only errors are below this pass's threshold. A document used
as an executable contract is rated by its consumer's failure. Do not promote a minor to
keep it in the report. Finding nothing is a valid result.

Each finding names a file and line, a concrete trigger and consequence, its lens, and
supported confidence. Distinguish pre-existing defects from those introduced by the change.
Report each defect once, even when several lenses expose it. Leave out taste, speculative
failure paths, and intentional behavior changes that meet the goal.
