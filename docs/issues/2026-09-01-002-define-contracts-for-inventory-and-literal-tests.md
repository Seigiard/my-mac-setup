---
title: "Define contracts for inventory and literal tests"
short_description: "Architecture inventories and externally consumed literals lack a policy that separates durable contracts from source mirrors, so weak assertions can block refactors without proving deployed behavior."
type: "follow-up"
category: "testing-ci"
tags: ["semantic-testing","source-ownership","literal-contracts"]
date: "2026-09-01"
status: "open"
priority: "medium"
---

## Why this exists

The 2026-09-01 test audit removed source-copy assertions only where behavioral or deployment owners already existed. Architecture inventory tests and exact literals were left unchanged because the repository does not state when source ownership, membership, labels, paths, commands, or schema fragments are externally consumed contracts rather than implementation details.

## Scope

Inventory the remaining architecture-list and exact-literal assertions. For each assertion, name its consumer and failure mode; keep and document externally consumed contracts, replace source mirrors with behavioral or deployment probes, and remove duplicates. Add concise test-author guidance and examples to the semantic regression testing solution and agent instructions without duplicating policy.

## Open decisions

Which source ownership and inventory relationships are stable repository contracts? Which literals are consumed by external tools, users, automation, or persisted state? Where should each surviving contract be documented, and which behavioral owner should replace every non-contract literal assertion?
