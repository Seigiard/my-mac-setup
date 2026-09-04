---
title: "herdr-child rejects Claude effort selection"
short_description: "ask-in-herdr forwards --effort to herdr-child, but herdr-child rejects it for Claude even though the installed Claude CLI supports low, medium, high, xhigh, and max effort levels."
type: "bug"
category: "herdr"
tags: ["ask-in-herdr","claude","model-selection"]
date: "2026-09-04"
status: "open"
priority: "medium"
---

## Why this exists

A requested Claude Sonnet review at medium effort failed before launch with 'herdr-child: --effort is not supported for claude'. The ask-in-herdr script accepts --effort and forwards it, while 'claude --help' confirms native --effort support. Callers must currently bypass the managed child transport to honor an explicit Claude effort request.

## Scope

Allow managed Claude children to receive supported native effort levels through herdr-child and ask-in-herdr. Keep invalid kind or level combinations fail-closed. Update the skill contract and focused coverage so documented flags match accepted behavior.

## Open decisions

Whether herdr-child should maintain a per-agent effort capability matrix or pass through effort whenever the installed client advertises native support.
