---
title: "Docker suite stalls in herdr-child reap test"
short_description: "After merging origin/main at 193198d, make test-ubuntu blocks in scripts_test.sh for over four minutes while herdr-child reap waits on an unreleased reap-owner lock; interrupting the process leaves make with exit 1."
type: "bug"
category: "testing-ci"
tags: ["bashunit","herdr-child","docker"]
date: "2026-09-01"
status: "open"
priority: "medium"
---

## Why this exists

`make test-ubuntu` on merged commit `af52a8d` stopped producing output in
`tests/bashunit/scripts_test.sh`. After more than four minutes, `docker top`
showed the active test blocked in:

```text
bash .../executable_herdr-child reap --pane wT:p9 child-life
python3 ... reap-owner.lock ... reap-owner.release ...
```

The run had already printed the surrounding herdr-child lifecycle passes. A
manual interrupt allowed the remaining idempotence suite to finish, but `make`
returned exit 1. Full Docker verification therefore remains incomplete even
though the Worktrunk-specific tests passed before the merge.

## Scope

- Reproduce the stall in the narrowest `scripts_test.sh` invocation.
- Identify which reap lifecycle case fails to release the owner lock.
- Add a bounded behavioral regression that fails instead of hanging.
- Verify `make test-ubuntu` completes without intervention.

## Open decisions

None.
