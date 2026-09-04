---
title: "Pre-external secret scan covers one of five external-peer launch paths"
short_description: "The gitleaks gate that once scanned every path shipping repo content to external models died with the Smithers runtime; se-code-review, se-simplify, se-plan and ask-in-herdr now start Claude and OpenCode peers over the live checkout with no scan, leaving se-doc-review's single-document scan as the only surviving coverage."
type: "bug"
category: "agent-platform"
tags: ["secret-scanning","gitleaks","external-llm","security-boundary","regression"]
date: "2026-09-04"
status: "open"
priority: "high"
---

## Why this exists

Repository content leaves this machine for two third-party model providers every time an
`se-*` review runs, and four of the five paths that send it perform no secret scan.

`home/private_dot_claude/shared/herdr-peer-launch.md` is the shared launch procedure. It
starts a Claude peer and an OpenCode peer rooted at `$REPO_ROOT` — the live checkout, not a
staged subset — with interactive permission prompts suppressed, so each peer reads whatever
the working tree contains. Five skills invoke it:

| Caller | Secret scan before launch |
|---|---|
| `se-doc-review` | yes — `gitleaks dir --no-banner --redact --exit-code 2 "$DOC_PATH"`, fail-closed |
| `se-code-review` | none |
| `se-simplify` | none |
| `se-plan` | none |
| `ask-in-herdr` | none |

`gitleaks` appears in exactly three tracked files: `se-doc-review/SKILL.md`,
`home/private_dot_config/brewfiles/Brewfile.tmpl`, and `tests/bashunit/templates_test.sh`.
The Brewfile comment now scopes the tool to that one caller.

This is a regression, not an oversight. The gap was found and closed on 2026-08-14 by a
shared gate, `enforcePreExternalGate` in `dot_smithers/workflows/lib/pre-external-gate.ts`,
which both standalone harnesses passed through before dispatching legs; a follow-up tree-tier
closed the pre-`baseSha` exposure on 2026-08-15. Commit `9376add` ("remove smithers", 2026-09-01)
deleted that gate along with the runtime, and nothing replaced it. The originating issues
(`2026-07-27-002`, `2026-08-14-009`, both closed done) were removed in the closed-issue cleanup.

Note that even the surviving scan is narrower than the one it replaced: `gitleaks dir` over a
single document, rather than a diff range or the tree.

## Scope

Restore a scan on every path that ships checkout content outside the machine, or record a
deliberate decision that some callers are exempt and why.

The guidance this violates is already captured in
`docs/solutions/architecture-patterns/pre-external-secret-boundary-for-coding-agent-pipelines.md`
and its rules still apply — in particular: pin the scanner's exit codes rather than treating
any nonzero as clean, pass `--redact` before any output is persisted, and fail closed when the
scanner is missing. Blast radius argues for fail-closed here, per
`docs/solutions/design-patterns/gate-bias-follows-blast-radius.md`: content that reaches a
third-party model cannot be recalled.

Decide where the check belongs. Putting it in `herdr-peer-launch.md` covers all five callers at
one site and cannot be forgotten by a new caller; putting it in each skill lets the scan scope
match what that skill actually sends. The repo legitimately tracks `op://` secret-reference
templates, so whatever lands must not fire on those.

## Open decisions

- One shared gate in `herdr-peer-launch.md`, or a per-caller scan scoped to each payload?
- What does each caller actually expose — the whole checkout, or a narrower set that a
  cheaper scan could cover?
- Does `ask-in-herdr` count as an external-dispatch path for this purpose, given it is a
  general-purpose peer consult rather than a review leg?
