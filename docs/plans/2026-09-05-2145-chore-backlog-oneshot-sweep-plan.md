# Backlog one-shot sweep

Iterate over the 17 open issues outside `command-palette` and `agent-platform`, and close every one
that closes cheaply. Each task gets one attempt by one subagent on its own branch. An attempt that
does not land in one shot is recorded as failed and the sweep moves on — this plan optimizes for
closed issues per hour, not for finishing the list.

All 17 records were audited against the tree on 2026-09-05 (commit `11ff7cb`), so their descriptions
are current. Three already-resolved records were closed in that audit and are not in this list.

## How this plan runs

This is a `se-orchestrator` plan with one deliberate divergence from the skill: the worker commits,
on its own branch, and the orchestrator integrates by squash-merge. Everything else holds — the
first unchecked box is where you continue, one item is one commit on the sweep branch, and the
checkbox rides in that commit.

Per item:

1. **Dispatch one subagent** with `isolation: "worktree"`, branch `sweep/<issue-id-short>`. Hand it
   the issue record, the verification commands from `CLAUDE.md`, and the guardrails below — not this
   whole plan. Tell it to commit on its branch and stop; it does not merge, push, or touch
   `docs/issues/`.
2. **Read the result yourself.** `git diff main...sweep/<id>` is the truth; the agent's summary is a
   hint about where to look. Run the verification yourself — never accept a reported pass.
3. **Classify the outcome** using the legend below, then act on it.
4. **Squash-merge on success:** `git merge --squash sweep/<id>`, then close the issue
   (`python3 scripts/issues start <id>` → `close --resolution "…"`), tick the box here, and make one
   commit through `ce-commit` carrying the code, the closure, and the `[x]` together. Delete the
   worker branch.

Serial only. Several items touch `home/dot_local/lib/herdr-child-*.sh` and
`tests/bashunit/scripts_test.sh`; that shared write surface is what forces the order.

### Outcome legend

Mark each item with exactly one on completion:

- `[x] done` — landed and merged, issue closed with a resolution naming what was verified.
- `[ ] failed` — the agent could not land it in one shot. Keep the box unchecked and add a
  `failed <date>:` line stating what it tried, what it saw, and what it thinks blocks the fix. Do
  not retry in this sweep.
- `[x] not-reproducible` — the premise does not hold against the current tree. Close the issue with
  a resolution recording exactly what you ran, what you observed, and on what platform. No code
  change, so the commit carries only the closure and the checkbox.
- `[ ] blocked` — the item needs a decision the agent cannot make. Add a `blocked <date>:` line
  naming the decision and who owns it, then move on.

A "not-reproducible" close is a real claim. It requires an observation, not the absence of one:
"I ran X on platform Y and saw Z" closes an issue; "I could not reproduce it" does not.

### Verification

Read the commands from `CLAUDE.md` at dispatch time rather than from this file. As of writing:

| Scope of the change | Run |
|---|---|
| Any change at all | `make lint`, `make test-issues` |
| One bashunit suite | `tests/lib/bashunit -j 8 tests/bashunit/<file>_test.sh` |
| Managed file under `home/` | `make test-local` (diff only; one-shot Bash call, never a pane) |
| Deployment-sensitive change | `make test-ubuntu` in a visible Herdr pane, per `docs/agent-verification.md` |

### Guardrails for every worker

- Never run `chezmoi apply` or bare `chezmoi init` on the host.
- Edit sources under `home/`, never the live files in `~/`.
- New tests pass the oracle gate first: name the consumer, the observable failure, and an oracle
  independent of the patch. When the line will not complete, write zero tests and say so.
- The worker never edits `docs/issues/` — issue lifecycle belongs to the orchestrator.
- Recursive delete is blocked; move unwanted paths to `~/.scratchpad/<name>-$(date +%s)`.

## Progress

Order is by risk, not by ease: silent supervision hangs first, then tests that cannot fail, then
environment papercuts, then the low-priority backlog. Items 8, 10, and 11 are the cheap ones — jump
to them first if the goal shifts to maximizing closures per hour.

### Runtime defects — herdr supervision

- [x] 1 · `2026-08-30-007` — expire abandoned herdr-child callback claims.
      `callback.state=in-progress` makes the watcher poll forever when the callback owner dies before
      publishing `confirmed`/`failed`. The state carries no owner PID, token, or timestamp
      (`herdr-child-continuation.sh:200-206`), so supervision can neither deliver nor recover.
      *Done when:* a dead owner's claim expires and the watcher reaches a terminal outcome, proven by
      a test that kills the owner rather than by asserting on the state file's shape.

- [x] 2 · `2026-08-30-009` — bound transient herdr-child pane-read retries.
      Neither the main poll loop (`herdr-child-watcher.sh:265-271`) nor delivery-time revalidation
      (return code 12 at `:368`, outside the `10|11` branch) counts failures against
      `MAX_DELIVERY_RETRIES`, so a persistent herdr transport or permission failure keeps supervision
      alive forever without delivering a lifecycle event.
      *Done when:* both paths share one retry budget and a sustained pane-read failure ends in a
      reported terminal state.

- [x] 3 · `2026-08-30-005` — stop the superseded watcher refreshing stale liveness.
      `refresh_supervision_liveness` (`herdr-child-supervision.sh:354-358`) publishes
      `supervised=<old generation>` with no under-lock generation precondition, unlike the failure
      publication at `:288` and `:296` which uses `metadata_report_if_generation`. A watcher already
      inside the refresh path can overwrite liveness after a managed takeover.
      *Done when:* the refresh carries the same generation precondition as the failure path, and a
      test drives a takeover mid-refresh.

- [ ] 4 · `2026-09-03-002` — enforce identity outcome transitions as a whitelist.
      No whitelist exists; `write_identity_state`
      (`home/dot_local/bin/executable_herdr-worktree-identity:289-301`) accepts any outcome string
      from ad-hoc branches.
      **Expect `blocked`.** The shipped vocabulary diverges from the plan's diagram in four ways
      (hyphenated `workspace-only`/`workspace-failed`; undocumented `workspace-prepared` and
      `branch-failed`; `pending` never written; `contended` only a diagnostic), so encoding the
      diagram as written would reject most live writes. Reconciling the chart is a naming decision
      the user owns. Dispatch only to confirm the divergence list is complete, then block on it.
      blocked 2026-09-05: audit complete — the divergence list was incomplete and is now nine
      outcomes wide in the record. Two additions: the engine's own spelling is mixed
      (`attribution_failed` underscored against four hyphenated names), so no chart can accept the
      shipped set unchanged; and the source plan's prose contradicts its own diagram, with the
      underscores most likely a mermaid `-->` syntax constraint rather than a naming intent.
      Decision the user owns: which spelling and membership the reconciled chart uses, and whether
      a rejected transition aborts the naming event or records a diagnostic. No code was changed.

- [x] 5 · `2026-08-30-010` — research simplifying the herdr-child lifecycle.
      2,701 lines and 79 functions across the entrypoint and six modules.
      **Not a one-shot coding task** — it is a research deliverable, and it depends on items 1-3
      landing first. Skip it in this sweep unless items 1-3 all closed, and even then expect a
      document, not a diff.

### Tests that cannot fail

- [x] 6 · `2026-09-04-002` — pane-label glyph assertions re-derive from the engine.
      `hpl_icon()` (`tests/helpers/herdr_pane_labels.bash:18-24`) seds each octal sequence out of the
      very engine it checks, so 26 `HPL_ICON_*` assertions in `scripts_test.sh` compare the engine
      against itself. The fix landed in PR #140 and was reverted seven hours later by the
      `herdr-task-sync` rename. A narrow independent pin survives at `tests/bashunit/smoke_test.sh:925-929`.
      *Done when:* the assertions compare against literals independent of the engine, and mutating a
      glyph in the engine turns them red.

- [x] 7 · `2026-09-02-012` — pane-label herdr stub is an unverified protocol fake.
      The stub bakes herdr's envelope shapes, its jq-built snapshot skeleton (`:265-267`), and the
      `--seq`/`--token` high-water merge semantics; nothing compares it to the real binary, and
      `d080d31` proved the drift class is realized.
      *Done when:* the emulated herdr version and protocol number are recorded beside the fixture and
      a host-only, skip-if-absent check compares real `herdr api snapshot` result keys against the
      stub's. Do not reimplement herdr semantics locally to make them testable.

- [ ] 8 · `2026-08-30-008` — bound the three remaining herdr-child test barriers.
      `HERDR_CHILD_TEST_TAB_CREATED_BARRIER`, `..._LAUNCH_POST_ARM_BARRIER`, and
      `..._CALLBACK_RECEIPT_BARRIER` still poll with no owner and no time bound
      (`herdr-child-launch.sh:243`, `:557`, `herdr-child-continuation.sh:317`), so a killed harness
      strands test processes. The shared bound already exists — `watcher_hold_expired`, used on four
      other barriers.
      *Done when:* all three use the existing bound and a killed harness leaves no stranded process.
      **Cheapest item in this plan.**

- [ ] 9 · `2026-09-02-011` — test-oracle-guard misses positive tautological tests.
      The engine fires only on negative-assertion patterns.
      **Expect `blocked`.** The audit inside the record already falsified the incident that motivated
      it and rejected the `oracle:`-comment mechanism on blast-radius grounds. What remains is
      whether the engine should gain a diff-aware positive check at all, given it needs patch state
      the stateless hook does not have — a design decision, not a one-shot fix.
      blocked 2026-09-05: needs a design decision from the user — whether the engine may reach for patch state (read the on-disk file, or shell out to `git diff`) to gain a positive check, accepting that its verdict then depends on commit timing, or whether the positive class stays prose-plus-review. The `oracle:`-comment mechanism is doubly dead: rejected on blast radius by the audit, and unimplementable because every adapter sends only the edit fragment.

- [ ] 10 · `2026-09-02-009` — superseded-watcher barrier test flaked once in CI.
      Test 040 (`tests/bashunit/scripts_test.sh:3068`) failed once in PR #135's `test-ubuntu` job
      despite a deterministic barrier scheme; four independent signals point to flake, not
      regression. It is not explained by `9f1b017` — `_bats_test_init 40` occurs exactly once, so the
      tmpdir-collision mechanism does not apply.
      **Most likely `not-reproducible`.** Run test 040 under load enough times to make a claim, then
      either close it with the observation or record the reproduction. Do not close it on a single
      quiet pass. Its body also cites two deleted issue files — drop those paths whatever the outcome.

### Environment papercuts

- [x] 11 · `2026-09-03-001` — `make lint` walks leftover agent worktrees.
      The `find` at `Makefile:62` excludes `./.git`, `./.worktrees`, `*/node_modules`, and
      `./.context`, but not `./.claude/worktrees`, so any leftover agent worktree's shellcheck
      findings can fail lint on an otherwise clean tree. `.gitignore` cannot fix it — `find` consults
      neither it nor `.git/info/exclude`.
      *Done when:* `-not -path "./.claude/worktrees/*"` is added and `make lint` passes with a
      deliberately dirty worktree present. **One-line fix; take it first if you want an early close.**

- [ ] 12 · `2026-09-05-005` — `update-all` should check pinned versions and offer bumps.
      `update-all` (`home/dot_aliases:294-299`) runs `brew update && brew upgrade --no-ask && skills
      update && mise upgrade` and never compares the pinned chezmoi-external refs (Oh My Zsh, four
      zsh plugins, fff-mcp) or mise tool versions against upstream. It replaces the removed
      `omz update`.
      *Done when:* each drifted pin is reported and offered interactively, and declining leaves the
      pins untouched. Network-dependent — the worker must handle upstream being unreachable.

### Low priority — herdr

- [ ] 13 · `2026-08-26-001` — signal race can orphan a tab before pane capture.
      Tab mode re-parses the buffered response (`herdr-child-launch.sh:197-206`), but
      `json_tab_identity` (`herdr-child-runtime.sh:267-277`) extracts the terminal id and prints only
      `pane\ttab`, so `launch_terminal` stays empty and `cleanup_pane` refuses the close at `:183`.
      Pane mode has no fallback at all. Test 66 injects its signal after the `read`, so the window is
      untested.
      *Done when:* `json_tab_identity` emits the terminal id, pane mode gets the same fallback, and a
      signal-injection test fires before the `read` in both modes.

- [ ] 14 · `2026-08-26-002` — launch-failure cleanup does not report tab state.
      `cleanup_pane` (`herdr-child-launch.sh:166-192`, reached from ~18 sites) ends at
      `herdr pane close` and never calls `tab_reap_status`, unlike `reap`
      (`herdr-child-reap.sh:158-164`).
      **A `wontfix` is a legitimate outcome here** and may be the right one: no launch-failure path
      realistically produces a sibling pane in a tab created moments earlier. Decide that first; if
      it holds, close with the reasoning recorded rather than implementing.

- [ ] 15 · `2026-08-17-001` — supervisor process subscribing to herdr agent-status events.
      No socket subscriber exists; `herdr api` in 0.8.2 exposes only `snapshot` and `schema`, though
      `api schema --json` already carries `events.subscribe`, `events.wait`, and
      `pane_agent_status_changed`.
      **Feature, not a defect.** Expect `failed` or a deferral from a one-shot attempt.

- [ ] 16 · `2026-08-18-003` — consulting a peer agent from outside herdr.
      `ask.sh:47-50` refuses when `HERDR_ENV != 1`; there is no headless mode.
      **Feature, not a defect.** Its body also cites the dead path
      `home/private_dot_claude/skills/ask-agent/scripts/ask.sh` — fix that reference whatever the
      outcome.

- [ ] 17 · `2026-08-18-019` — add manual AgentBox sessions to Herdr.
      Zero AgentBox adoption in the tree. Depends on two open `agent-platform` records that are out
      of this sweep's scope, and on upstream AgentBox's CLI surface, which nobody has verified here.
      **Expect `blocked`.** Verify the upstream surface before deciding anything.

## Finish

When every item is checked, failed, or blocked:

1. Run `se-code-review` once over the whole sweep branch.
2. Apply clear, reversible findings. Leave taste calls and reviewer contradictions to the user.
3. Re-run `make lint`, `make test-issues`, and the suites the sweep touched. Run `make test-ubuntu`
   if any managed file under `home/` changed.
4. Report: issues closed, issues left failed with their reasons, issues blocked with the decision
   each needs.

Push and PR are a separate explicit request through `ce-commit-push-pr`.
