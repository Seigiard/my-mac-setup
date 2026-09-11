---
title: "Make External leg pair lifecycle executable"
short_description: "Replace the prose-only paired peer lifecycle with one tested executable that owns scanning, launch, report transport, classification, and cleanup for three review workflows."
type: "follow-up"
category: "se-pipeline"
tags: ["architecture","external-leg","semantic-tests","enhancement","ready-for-agent"]
date: "2026-09-11"
status: "done"
priority: "high"
closed: "2026-09-11"
---

## Why this exists

se-code-review, se-doc-review, and se-simplify currently reenact a 206-line Markdown procedure, so lifecycle safety and cleanup are not enforced through an executable test surface.

## Scope

Add se-external-leg-pair with fixed launch policy, exact exposed-content scanning, atomic result publication, degraded-coverage classification, and fail-closed cleanup; migrate the three callers and reduce herdr-peer-launch.md to interface documentation. Preserve SE_SKIP_SECRET_SCAN=1 with an explicit waived result.

## Open decisions

None. The interface and caller ownership decisions were accepted during the architecture review.

## Resolution

Implemented the executable External leg pair lifecycle, migrated all three callers, added semantic regression coverage, and verified the deployed checkout with make test-ubuntu.
