---
title: "Select External leg models by complexity and effort"
short_description: "se-external-leg-pair now requires provider-neutral complexity and effort, resolves a versioned Claude/OpenCode launch matrix centrally, and publishes the requested and resolved settings with each result."
type: "follow-up"
category: "se-pipeline"
tags: ["external-leg","agent-models","cli-contract","herdr"]
date: "2026-09-12"
status: "done"
priority: "medium"
closed: "2026-09-12"
---

## Why this exists

`se-external-leg-pair` owns the shared lifecycle for code review, document review, and simplification, but it currently hardcodes Claude Sonnet with high effort and OpenCode Terra. New paired workflows need different capability and reasoning budgets without copying provider model IDs into every skill or duplicating the launch, scan, transport, classification, and cleanup lifecycle.

## Scope

- Require every caller to provide `--complexity low|medium|high|xhigh` and `--effort low|medium|high|xhigh|max`; omit both defaults and refuse missing or unsupported values before creating tabs.
- Keep the pair invariant: exactly one Claude leg and one OpenCode leg receive the same scope. Leg omission and arbitrary provider selection remain outside this interface.
- Map both semantic inputs to provider-specific model and effort or variant flags inside the executable. Callers never pass model IDs.
- Establish and test a versioned mapping against the installed clients model catalogs. The semantic combination assigned to current callers must preserve their Sonnet/high and Terra behavior during migration.
- Update all repository callers and `herdr-peer-launch.md` to declare intent explicitly.
- Publish requested semantic values and resolved per-leg launch settings in the result for cost and tuning diagnostics.
- Add semantic tests for argument validation, each mapping, forwarded launch arguments, and pre-tab refusal. Preserve existing scan, retry, transport, degradation, and cleanup behavior.
- Do not add arbitrary raw-model overrides, runtime network discovery, a single-leg mode, or a second lifecycle executable.

## Open decisions

The semantic API and pair invariant are settled. Before implementation, verify the exact initial provider/model matrix, especially `xhigh` and provider-specific support for each effort value, against the installed client catalogs rather than inferring capability from model names.

## Resolution

Implemented required complexity and effort inputs, centralized the versioned provider mapping, migrated all callers to medium/high, published selection diagnostics, and added focused lifecycle plus installed-client conformance coverage.
