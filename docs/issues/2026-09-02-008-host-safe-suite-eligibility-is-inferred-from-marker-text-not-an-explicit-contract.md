---
title: "Host-safe suite eligibility is inferred from marker text, not an explicit contract"
short_description: "Each post-apply suite now declares ordered host eligibility in a leading machine-readable tag that tests/run-post-apply.sh consumes and validates at runtime; the contract test verifies the runner's observed partition."
type: "follow-up"
category: "testing-ci"
tags: ["post-apply-suite","test-discovery","semantic-testing"]
date: "2026-09-02"
status: "done"
priority: "medium"
closed: "2026-09-02"
---

## Why this exists

A cross-model review of tests/test_post_apply_suite_contract.py (branch test/ci-and-post-apply-failure-propagation) found that the host-safe/full partition in discovered_suite_files() classifies a suite file as unsafe-for-host by grepping its raw text for the co-occurrence of the literal strings MMS_DISPOSABLE_HOME and GITHUB_ACTIONS, then asserting exactly one discovered file matches. This currently isolates idempotent_test.sh correctly because it is the only suite file whose hard-fail guard (real chezmoi apply, gated on a disposable $HOME) happens to reference both strings, and scripts_test.sh's unrelated single-marker mentions of MMS_DISPOSABLE_HOME do not also mention GITHUB_ACTIONS. But the test infers eligibility from what a file's comments and code happen to say, not from a contract the runner itself reads and enforces. A future suite file that performs a real chezmoi apply without carrying those exact two literal strings (e.g. a differently worded guard, or a guard added later without the GITHUB_ACTIONS reference) would be silently admitted to host-safe execution; conversely, a suite file that merely mentions both strings in a comment for unrelated reasons could be wrongly excluded from host-safe. The reviewer's proposed alternative: give suite files an explicit, machine-readable eligibility declaration that tests/run-post-apply.sh itself consumes when building the host-safe file list (for example, a fixed marker comment at a known location, or a companion manifest), then have the contract test assert against that declaration and the runner's *observed* behavior instead of inferring intent from prose. This was correctly left out of the test-only branch that surfaced it (test/ci-and-post-apply-failure-propagation, commits 3a4323c..3b43f71): changing run-post-apply.sh's suite-selection mechanism is a production behavior change, not a test hardening, and doing it without dedicated design review risked destabilizing the exact wrapper the branch was strengthening test coverage for.

## Scope

Design and implement an explicit eligibility declaration for tests/bashunit/*_test.sh suite files (e.g. a required leading comment tag like '# post-apply: needs-disposable-home', or a small manifest file) that tests/run-post-apply.sh reads to build its full and host-safe file lists, replacing the current hardcoded 'files=' shell variables. Update tests/test_post_apply_suite_contract.py's discovered_suite_files()/guard detection in tests/test_post_apply_suite_contract.py:49-54 to assert against that declaration and the runner's real behavior, rather than grepping for MMS_DISPOSABLE_HOME+GITHUB_ACTIONS co-occurrence. Preserve the existing disk-discovery guarantee (a new *_test.sh file not covered by full mode fails the contract test) and the mutation-provable partition between full and host-safe.

## Open decisions

Whether the eligibility declaration lives as a per-file comment convention (grep-friendly, no new file format) or a small YAML/JSON manifest (more structured, another file to keep in sync). Whether run-post-apply.sh should validate the declaration at runtime (fail loudly on a malformed or missing tag) or only the test suite enforces it statically.

## Resolution

Added ordered per-file post-apply eligibility declarations, made the runner discover and validate them for full and host-safe modes, and replaced marker-text inference with observed runner behavior plus malformed-declaration coverage. Verified with make test-issues, make lint, and make test-suite.
