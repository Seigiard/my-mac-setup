---
allowed-tools: Bash(touch:*), Bash(test:*), Bash(cat:*)
description: Approve a specification phase
argument-hint: requirements|design|tasks
---

## Context

Current spec: !`cat spec/.current-spec 2>/dev/null`
Spec directory: !`ls -la spec/$(cat spec/.current-spec)/ 2>/dev/null`

## Your Task

For the phase "$ARGUMENTS":

1. Verify the phase file exists (requirements.md, design.md, or tasks.md)
2. Create approval marker file: `.${ARGUMENTS}-approved`
3. Inform user about next steps:
   - After requirements → design phase
   - After design → tasks phase
   - After tasks → implementation
4. If invalid phase name, show valid options

Use touch command to create approval markers.
