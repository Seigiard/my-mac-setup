---
title: "Define contracts for inventory and literal tests"
short_description: "The audit confirmed dependent oracles in CI event policy, post-apply routing and inventory, Herdr glyph and relink wiring, Git ignore behavior, palette fallback parsing, and Bats scan scope; each needs an independent consumer boundary."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-testing","source-ownership","literal-contracts"]
date: "2026-09-01"
status: "open"
priority: "medium"
---

## Why this exists

The 2026-09-01 test audit removed source-copy assertions only where behavioral or deployment owners already existed. A repository-wide follow-up audit then confirmed these dependent oracles:

- `tests/test_ci_workflow.py:65-100` derives expected cache events from the workflow expression under test.
- `tests/test_post_apply_suite_contract.py:17-58` counts command text and copies the runner's suite inventory; `tests/test_docker_contract.py:70-94` accepts a matching command even when its failure is suppressed.
- `tests/helpers/herdr_task_sync.bash:12-34` extracts expected user-facing glyphs from the implementation that emits them.
- `tests/bashunit/smoke_test.sh:956-968` greps onchange-template includes without proving that dependency changes alter the rendered hash.
- `tests/test_issues.py:518-522` inspects `.gitignore` source instead of Git's effective decision.
- `tests/bashunit/palette_test.sh:527-555` exercises the fallback parser with expected values copied from mutable production configuration.
- `tests/test_bats_assertion_contract.py:128-136` accepts the checker's own file inventory without an independent reachability fixture for every supported test-shell surface.

Each test can stay green while its consumer-visible behavior breaks, or fail after a harmless source refactor. Architecture inventory tests and exact literals remain valid only when they compare independent sides or protect a literal consumed externally.

## Scope

Replace the confirmed dependent oracles at their strongest consumer boundaries:

- Pin the CI event policy independently, then compare workflow conditions with the explicit minimal and full event sets.
- Discover post-apply consumers and eligible suites independently; execute a failing wrapper through each gate and require nonzero status to propagate.
- Define stable Herdr glyphs independently if exact glyphs are a user contract; otherwise assert semantic token roles without copying implementation literals.
- Render the onchange template before and after mutating each dependency and require its hash to change.
- Use `git check-ignore` and tracked-path evidence for ignore behavior.
- Give the fallback TOML parser a minimal fixed fixture independent of `commands.toml`.
- Add reachability fixtures for every shell-file class the Bats assertion checker claims to protect.

Keep and document externally consumed command, transport, schema, symlink, and rendered-config literals. Keep one behavioral, deployment, or validation owner per contract. Safe deletions belong to `2026-09-01-003`; Pi hook and updater coverage gaps belong to `2026-09-01-004`; updater failure notifications belong to `2026-08-21-022`.

## Open decisions

- Whether Herdr's exact glyph set is stable user-facing policy or replaceable presentation.
- Whether post-apply suite eligibility should be derived from file metadata, a canonical manifest consumed by the runner, or another independent rule.
- Which sourced shell-helper classes must be covered by the Bats assertion checker.
- Which remaining deployment inventories in smoke and template suites are deliberate machine-setup policy rather than current source-tree shape.
