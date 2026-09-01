---
title: "Remove source-mirror assertions with stronger behavioral owners"
short_description: "The test audit found internal module inventories and a stale duplicate Pi package smoke check that add correlated maintenance without detecting failures beyond existing lifecycle and modifier tests."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-testing","duplicate-coverage","source-ownership"]
date: "2026-09-01"
status: "open"
priority: "medium"
---

## Why this exists

The repository-wide tautological-test audit identified assertions that can be deleted without losing an independently observable verdict. tests/bashunit/scripts_test.sh:7501-7653 hardcodes herdr-child module source order, function ownership, and allowed globals even though command-level lifecycle tests already exercise launch, supervision, continuation, and reap behavior. tests/bashunit/smoke_test.sh:402-416 duplicates the Pi package inventory owned by the settings modifier test and has already drifted by omitting npm:pi-ask-user.

## Scope

Remove the herdr-child source-order, function-ownership, and global-ownership inventories while retaining the sourceability, no-output, shell-state, redefinition, and global-mutation checks at tests/bashunit/scripts_test.sh:7538-7618. Remove the duplicate Pi package inventory from smoke_test.sh and keep tests/bashunit/scripts_test.sh:6883-6943 as the single modifier transformation and idempotency owner. Run the narrow shell suites and confirm each deleted assertion had no distinct consumer or failure mode.

## Open decisions

None. If implementation reveals an externally consumed module or package-membership contract not covered by the retained owners, stop and move that assertion under the replacement-oracle issue instead of deleting it.
