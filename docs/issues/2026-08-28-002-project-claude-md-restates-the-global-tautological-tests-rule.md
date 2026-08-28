---
title: "Project CLAUDE.md restates the global tautological-tests rule"
short_description: "The my-mac-setup test block duplicates two meanings now owned by the global CLAUDE.md"
type: "chore"
category: "repository-maintenance"
tags: ["claude-md","duplication"]
date: "2026-08-28"
status: "open"
priority: "low"
---

## Why this exists

The global instructions at home/private_dot_claude/CLAUDE.md gained an 'adding or reviewing tests' block stating that a test must change verdict when the protected behavior breaks and that exact-text assertions are valid only against an externally consumed literal contract. The project CLAUDE.md test block already carries both meanings ('A regression test is complete only when it goes red for the intended regression and green for the corrected behavior' and 'Assert externally observable behavior. Assert literal source or rendered text only when consumers depend on that exact shape'). The global file has the broader scope and is the right owner, which makes the project lines the duplicate — two copies that can drift and that both spend context on every turn in this repo.

## Scope

Trim the overlapping lines from the project CLAUDE.md test block, keeping its repo-specific content (suite selection, MMS_DISPOSABLE_HOME, control fixtures) and its pointer to docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md. Verify the solutions doc itself does not become the third copy.

## Open decisions

Whether the solutions doc or the global CLAUDE.md should be the single authority once the project restatement is removed.
