---
title: "test-oracle-guard misses positive tautological tests"
short_description: "Retired: the write-path policy caught only negative assertions, and the positive form needs the other side of the diff that the pure, stateless policy core cannot see, so the gate was deleted and the tautology class moved to the review pass under 2026-09-06-007."
type: "follow-up"
category: "testing-ci"
tags: ["test-oracle","hooks"]
date: "2026-09-02"
status: "done"
priority: "medium"
closed: "2026-09-06"
---

## Why this exists

The shared policy `home/dot_local/lib/agent-hooks/policies/test-oracle-guard.ts` fires only on negative-assertion patterns (`assert_not_contains`, `refute_match`, `! grep`, ...). In the 2026-09-02 ghostty-workspace-shortcuts session, an agent added two positive tests to `tests/bashunit/palette_test.sh` whose expected values (new command-kind names) came from the same patch that introduced them — the textbook tautology the CLAUDE.md gate forbids — and all three client hooks (Claude Code, OpenCode, Pi) stayed silent because no negative pattern was present. Prose alone did not stop it; the enforcement layer has a structural blind spot.

## Scope

Extend the policy with a low-false-positive signal for positive tautologies, or explicitly decide the class stays prose-only. Candidate mechanism: require an `oracle:` comment within N lines above every *new* test function in a proposed edit (the existing escape-hatch convention, applied at function granularity instead of only on flagged negative lines). Weigh blast radius per `docs/solutions/design-patterns/gate-bias-follows-blast-radius.md` — this would touch every new test in every repo across all three clients. The three client adapters carry no policy logic; touch `home/dot_local/lib/agent-hooks/normalize.ts` only if the check needs a field the normalized event does not already carry.

## Audit result (2026-09-02)

A repository-wide audit for positive tautologies ran over all ~600 tests in
`tests/` — the four bashunit suites, the five Python suites, the two Bun
suites, and the shared helpers.

**The incident this issue cites did not happen as recorded.** No commit on any
ref adds the two positive tests to `tests/bashunit/palette_test.sh` described
above, and no version of that file or its `tests/palette.bats` ancestor has
ever contained the string `ghostty`. The closest real match is
`test_palette_058`/`059`, whose expected values (`"New worktree"`,
`worktrunk.open`, `worktrunk.remove`, `worktrunk.merge`) did come from the
`commands.toml` entries added in the same patch — the exact tautology shape —
and which `4adc681` deleted on 2026-09-02. Nothing matching the description
survives in the file. The policy extension is therefore the only live item
here; the incident is not evidence for it.

**The audit is evidence, though, and it argues against the candidate
mechanism.** Two HIGH findings were confirmed by mutation, and neither would
have been caught by requiring an `oracle:` comment on every new test function,
because both were written *with* a plausible oracle in mind:

- `tests/test_post_apply_suite_contract.py` pinned `-j 8`, a production
  default that `tests/run-post-apply.sh` explicitly declares overridable. The
  test was red under `MMS_BASHUNIT_JOBS=4` — the value CI's own macOS job sets
  since `c029819` — and blind to the wrapper dropping the operator's cap.
- `tests/pi-brew-auto-update.test.ts` named two tests for git-revision
  behavior while injecting `snapshotExtensions` wholesale, so the production
  git branch never ran. Blinding `captureExtensionSnapshot` to every
  git-installed extension left all 27 tests green.

The rest of the corpus yielded no further HIGH findings: about twenty
MEDIUM/LOW restatements, mostly an expected value transcribed from the
artifact under test while a stronger neighbour already owned the contract.
Against that base rate, a mandatory `oracle:` comment on every new test
function in every repo across all three clients is high friction for a signal
that missed both real failures. Per
`docs/solutions/design-patterns/gate-bias-follows-blast-radius.md`, the blast
radius does not justify it.

What the audit suggests instead, in decreasing confidence: a check that fires
when a test's expected literal also appears in a non-test file changed by the
same patch (narrow, needs the diff the stateless hook does not have today),
and treating "no mutation proof" rather than "no oracle comment" as the
reviewable gap — every fix in this audit carried one.

## Open decisions

**Superseded in part.** The question of whether `oracle:` on every new test
function is acceptable friction is answered no by the evidence above. What
remains open is whether the policy should gain a diff-aware positive check at
all, given that it would need session or patch state the stateless dispatch core
does not have, or whether the positive class stays prose-plus-review.

## Input contract measured (2026-09-05, re-pointed after the core port)

The policy's interface is `evaluate(event: NormalizedEvent)`, reading
`event.filePath` and `event.content`. The bash engine and the three hand-written
per-client adapters this section originally measured are retired; the same
per-dialect reads now happen once, in
`home/dot_local/lib/agent-hooks/normalize.ts`, which joins the full-content and
edit fields into `content`:

| Client dialect | Content the core aggregates into `event.content` |
|---|---|
| Claude Code | `tool_input.content`, `tool_input.new_string`, and the `new_string` of each `edits[]` entry |
| OpenCode | `args.content` and `args.newString` |
| Pi | `input.content` and the `newText` of each `edits[]` entry |

The consolidation changed where the reads live, not what reaches the policy, so
both consequences below survive the port intact and still constrain any positive
check built on this contract:

- **On an `Edit` the policy sees a fragment, not a file.** Every dialect carries
  only the replacement text. A rule phrased over "every new test function" cannot
  reliably find a function boundary, because the opening line, the closing line,
  or both may sit outside the fragment. The `oracle:`-comment mechanism the audit
  already rejected on blast-radius grounds is also not implementable as specified.
- **The policy has no second side to compare against.** The check the audit
  recommends — flag an expected literal that also appears in a non-test file
  changed by the same patch — needs the rest of the patch. Nothing in the
  contract carries it.

The policy could reach for patch state itself rather than receive it: read the
on-disk file for the pre-edit side, or shell out to `git diff` for the
concurrently changed non-test files. Both are real options and both are a design
change, not a fix. Reading the working tree makes the gate's verdict depend on
whether the source change is still uncommitted, so in a repository that commits
per unit — the convention here — the same test edit is flagged or cleared
depending only on commit timing. That is the tradeoff the open decision turns on.

## Resolution

Resolved by retiring the gate rather than extending it. The policy home/dot_local/lib/agent-hooks/policies/test-oracle-guard.ts is deleted, unregistered from policies/index.ts, dropped from the shared fixture corpus, and its deployed path added to home/.chezmoiremove. A diff-aware positive check was rejected on three grounds: the record's own audit showed the proposed oracle:-per-test mechanism would have caught neither confirmed HIGH failure; the required capability breaks the documented pure, no-I/O contract on Policy.evaluate in types.ts rather than extending it; and a working-tree read makes the verdict depend on commit timing, which in a repository that commits per unit is worse than no gate. The tautology class moves to the review pass, where the whole diff is already available - tracked as 2026-09-06-007. Between removal and that replacement, the class is unenforced by machine, which is accepted.
