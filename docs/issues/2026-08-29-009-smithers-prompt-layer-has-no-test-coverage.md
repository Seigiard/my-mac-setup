---
title: "Smithers prompt layer has no test coverage"
short_description: "buildReviewerPrompt and inboundPromptNote are exported but imported by no test, and consult-prompt.ts, flow-spec.ts and gate-announce.ts have no test file at all, so the prompt-construction layer of the se-pipeline is unverified while the rest of the Smithers suite runs ~96% behavioral."
type: "bug"
category: "se-pipeline"
tags: ["test-coverage","prompts","smithers"]
date: "2026-08-29"
status: "wontfix"
priority: "medium"
closed: "2026-08-31"
---

## Why this exists

A 2026-08-29 audit surveyed all 24 Smithers test files (~516 test cases) expecting to find
prompt-mirroring — tests asserting that a generated prompt contains a phrase written
verbatim in its own template. Almost none exists. The reason is that the prompt layer is
not tested at all.

- `home/private_dot_claude/dot_smithers/workflows/lib/reviewer.ts:47` — `buildReviewerPrompt`
  is exported and imported by no test file.
- `home/private_dot_claude/dot_smithers/workflows/lib/archive.ts:151` — `inboundPromptNote`
  is exported and imported by no test file.
- `lib/consult-prompt.ts` (91 lines), `lib/gate-announce.ts` (43 lines) — no test file.
- `lib/flow-spec.ts` (116 lines) — no test file; partially reached only through
  `flow-validate.test.ts` importing `isReservedBlockId` and `isValidBlockIdGrammar`.

This is an absence of coverage rather than a test-quality defect, and it stands out because
the rest of the suite is unusually strong: no mocks or spies anywhere, and roughly 96% of
cases run real git repositories, real sqlite, and real subprocesses while asserting computed
outcomes.

## Scope

Add tests that assert prompt structure rather than prompt wording, so they survive a
copy-edit but fail on a construction bug:

- Required sections are present in the built prompt.
- Injected variables are actually interpolated — a supplied plan path, diff, or reviewer
  role appears in the output, and a missing one is reported rather than silently emitted as
  an empty string.
- The correct block or profile is selected for a given input.

Cover `consult-prompt.ts` and `gate-announce.ts` with their own test files, and give
`flow-spec.ts` coverage beyond the two grammar helpers `flow-validate.test.ts` reaches.

Verify with `make test-smithers`.

## Open decisions

Whether `flow-spec.ts` warrants a dedicated test file or is adequately covered by extending
`flow-validate.test.ts`, which already imports part of it. Deciding this needs a read of how
much of the module is reachable through the validator's public surface.

## Resolution

The untested Smithers prompt layer was removed with the pipeline implementation.
