---
title: "Define contracts for inventory and literal tests"
short_description: "The audit's seven confirmed dependent oracles are now split across four implementation issues (2026-09-02-002 through 2026-09-02-005); this issue remains the registry of the shared rule and closes when all four land."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-testing","source-ownership","literal-contracts"]
date: "2026-09-01"
status: "open"
priority: "medium"
---

## Why this exists

The 2026-09-01 test audit removed source-copy assertions only where behavioral or deployment owners already existed. A repository-wide follow-up audit then confirmed seven dependent oracles. Each can stay green while its consumer-visible behavior breaks, or fail after a harmless source refactor.

The shared rule they violate: architecture inventory tests and exact literals are valid only when they compare independent sides of a relationship, or protect a literal consumed outside the repository.

## Scope

This issue owns the rule and the split, not the code. The seven findings are implemented under four children:

- `2026-09-02-002` — CI cache event policy (`tests/test_ci_workflow.py:65-100`), post-apply suite inventory (`tests/test_post_apply_suite_contract.py:17-58`), and suppressed Docker failure (`tests/test_docker_contract.py:70-94`).
- `2026-09-02-003` — onchange template hash (`tests/bashunit/smoke_test.sh:956-968`) and palette fallback parser fixture (`tests/bashunit/palette_test.sh:527-555`).
- `2026-09-02-004` — Git ignore behavior (`tests/test_issues.py:517-521`) and Bats assertion checker reachability (`tests/test_bats_assertion_contract.py:128-136`).
- `2026-09-02-005` — Herdr task-sync glyphs (`tests/helpers/herdr_task_sync.bash:12-34`).

Across all four: keep and document externally consumed command, transport, schema, symlink, and rendered-config literals, and keep exactly one behavioral, deployment, or validation owner per contract. Safe deletions belong to `2026-09-01-003`; Pi hook and updater coverage gaps belong to `2026-09-01-004`; updater failure notifications belong to `2026-08-21-022`.

Close this issue once the four children are closed and no further dependent oracle remains from the audit list.

## Open decisions

- Which remaining deployment inventories in the smoke and template suites are deliberate machine-setup policy rather than a mirror of the current source tree. This one is not delegated to a child; it needs a repository-wide answer.
