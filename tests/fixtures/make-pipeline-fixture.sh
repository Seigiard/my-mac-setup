#!/usr/bin/env bash
# Generates a throwaway fixture repo for se-pipeline runs (U7): a tiny bun
# project with one helper, green tests, and an implementation-ready plan for a
# second helper. Reproducible: same content every time, fresh git history.
# Usage: make-pipeline-fixture.sh [target-dir]   (default: mktemp under $TMPDIR)
set -euo pipefail

dir="${1:-$(mktemp -d "${TMPDIR:-/tmp}/se-pipeline-fixture-XXXXXX")}"
mkdir -p "$dir/src" "$dir/docs/plans"

cat > "$dir/package.json" <<'EOF'
{
  "name": "se-pipeline-fixture",
  "private": true,
  "type": "module"
}
EOF

cat > "$dir/src/greet.ts" <<'EOF'
export function greet(name: string): string {
  return `Hello, ${name}!`;
}
EOF

cat > "$dir/src/greet.test.ts" <<'EOF'
import { describe, expect, test } from "bun:test";
import { greet } from "./greet.ts";

describe("greet", () => {
  test("greets by name", () => {
    expect(greet("Ada")).toBe("Hello, Ada!");
  });
});
EOF

cat > "$dir/docs/plans/fixture-reverse-plan.md" <<'EOF'
---
title: Add reverse helper - Plan
type: feat
date: 2026-07-15
topic: reverse
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

# Add reverse helper - Plan

## Goal Capsule

- **Goal:** add a `reverse(input: string): string` helper to this fixture project with bun tests.

## Product Contract

### Requirements

- R1. `reverse` returns the input string with characters in reverse order.
- R2. Empty input returns the empty string.

### Acceptance Examples

- AE1. **Covers R1.** `reverse("abc")` → `"cba"`.
- AE2. **Covers R2.** `reverse("")` → `""`.

## Planning Contract

### Key Technical Decisions

- KTD1. Plain exported function in `src/reverse.ts`, mirroring `src/greet.ts`. No dependencies.

## Implementation Units

### U1. reverse helper + tests

**Goal:** implement `reverse` per R1/R2 with bun tests.
**Requirements:** R1, R2.
**Dependencies:** none.
**Files:** create `src/reverse.ts`, `src/reverse.test.ts`.
**Approach:** follow `src/greet.ts` / `src/greet.test.ts` structure.
**Execution note:** test-first; observe the red run before implementing.
**Test scenarios (bun test):** happy: AE1; edge: AE2, single character; error: none (pure function).
**Verification:** `bun test` green.

## Verification Contract

| Command | What it checks | Units |
|---|---|---|
| `bun test` | reverse behavior R1/R2 | U1 |

## Definition of Done

- `bun test` green; `reverse` exported from `src/reverse.ts`.
EOF

git -C "$dir" init -q -b main
git -C "$dir" -c user.email=fixture@local -c user.name=fixture add -A
git -C "$dir" -c user.email=fixture@local -c user.name=fixture commit -qm "init: fixture project with greet and reverse plan"

echo "$dir"
