# Open issues — grouped summary

Partial index, last touched 2026-08-21. It is **not** a current snapshot: the
grouped tables below list 39 issues, while
`rg -l 'status: open|status: in-progress' docs/issues` matches 51 issue files.
The ~12 missing rows are tracked in
[2026-08-21-013](2026-08-21-013-open-issues-index-is-not-a-full-snapshot.md);
query the tree directly when completeness matters. Regenerate this file after
closing or filing issues; it is a derived index, not a source of truth.

Severity scale:

- **Critical** — breaks the working loop or security right now.
- **High** — has already cost money/time and will recur.
- **Medium** — real risk or noticeable friction.
- **Low** — idea or improvement; nothing breaks without it.

## 1. Broken verification signal (tests and CI)

Until these are fixed, neither CI nor a local pre-push run is a trustworthy green/red.

| Issue | Summary | Severity |
|---|---|---|
| [2026-08-18-022](2026-08-18-022-install-smithers-dependencies-in-github-ci.md) | GitHub CI red on main: tests invoke `se flow` without bun and without source-tree smithers `node_modules` | **Critical** |
| [2026-08-19-001](2026-08-19-001-make-test-ubuntu-fails-two-tests-on-main.md) | `make test-ubuntu` fails two tests on main: the Docker harness lacks two setup steps GitHub CI has, so the local suite is not a faithful CI stand-in | **High** |
| [2026-08-20-002](2026-08-20-002-coordinator-location-test-flake.md) | Coordinator eight-pane location test flakes at the 1000 ms envelope boundary under load | Medium |
| [2026-08-20-010](2026-08-20-010-two-herdr-task-sync-tests-flake-under-full-suite-load.md) | Two herdr-task-sync ordering tests flake under full-suite load; root cause found 2026-08-21 (a 5 s `kill -9` engine watchdog calibrated on an idle machine) and fixed, the remaining ask is a failure-path state dump | Low |
| [2026-08-21-011](2026-08-21-011-pi-brew-test-unresolvable-path-in-docker.md) | The Pi brew auto-updater test imports `../home/...`, which does not resolve under the Docker mount layout, so `make test-ubuntu` is red on main | **High** |
| [2026-08-21-012](2026-08-21-012-macos-suite-misses-the-60-percent-wall-time-gate.md) | The parallel post-apply suite lands at 67% of baseline on the macOS CI job against a 60% target; stable, so this is the deferred residual, not a regression | Low |
| [2026-08-21-013](2026-08-21-013-open-issues-index-is-not-a-full-snapshot.md) | This index lists 39 of 51 open issues, so "is it already filed?" gets a wrong answer from it | Low |
| [2026-08-21-014](2026-08-21-014-fail-open-assertions-no-longer-catch-a-slow-fail-open.md) | Three "fails open promptly" assertions widened 2s -> 20s to survive --jobs load; they still catch a hang but no longer catch a 3-18s slow fail-open | Medium |
| [2026-08-21-015](2026-08-21-015-capture-the-idle-machine-wall-clock-pattern.md) | The same idle-machine wall-clock defect has been diagnosed from scratch four times; capture it in docs/solutions | Low |

## 2. se-pipeline / Smithers — money and lost runs

| Issue | Summary | Severity |
|---|---|---|
| [2026-08-18-026](2026-08-18-026-preserve-verification-command-working-directories.md) | The Verification Contract fallback parser drops each command's working directory → false red work gate; a paid work leg was wasted in `run-1787064382632` | **High** |
| [2026-08-20-009](2026-08-20-009-se-simplify-apply-timeout-budget.md) | se-simplify apply leg killed at the 20-min `APPLY_TIMEOUT_MS`; the agent spent 12.5 min on unrequested baseline test runs and every edit was reverted | **High** |
| [2026-08-14-015](2026-08-14-015-run-budgets.md) | `se pipeline` has no budget flag at all; two failed runs burned $16 with no warning and no cap | Medium |
| [2026-08-14-020](2026-08-14-020-pipeline-launch-surface.md) | Launch surface asks eleven things the operator cannot know; `--until=pr` is advertised and refused; the two flags that matter are hidden | Medium |
| [2026-08-14-008](2026-08-14-008-doc-review-path-has-no-live-coverage.md) | Verify-doc advisory path mostly proven by a live run; only the P0 waive half remains uncovered | Low |
| [2026-08-15-005](2026-08-15-005-se-flow-has-no-main-checkout-escape-diagnosis.md) | se-flow reports "no content change" instead of naming a main-checkout escape; the doorway that caused it is already closed | Low |

## 3. Child-agent security and reliability

| Issue | Summary | Severity |
|---|---|---|
| [2026-08-18-002](2026-08-18-002-sandbox-a-child-agents-filesystem-access.md) | `"*": "allow"` external-directory read grant applies to every opencode session on the machine, including credential-bearing paths; the sandbox that was the condition for this grant does not exist yet | **Critical** (security) |
| [2026-08-18-001](2026-08-18-001-launch-time-permission-mode-for-child-agents.md) | A "read-only" child inherits `bypassPermissions` and can still write through its shell; launch-time permission modes were the option not taken | **High** |
| [2026-08-18-021](2026-08-18-021-harden-child-agent-ownership-and-launch-cleanup.md) | `herdr-child` enforces no ownership: a parent can target an unrelated live agent; a malformed split response can orphan a pane | Medium |
| [2026-08-17-001](2026-08-17-001-herdr-event-subscription-supervisor.md) | A parent loses a hung or crashed child; a supervisor subscribed to `pane_agent_status_changed` would close the gap the callback contract accepts | Medium |
| [2026-08-18-018](2026-08-18-018-run-smithers-pipeline-agents-in-microsandbox.md) | Upgrade Smithers 0.32 → 0.35 (`smthrs`) and trial a Microsandbox provider with Herdr visibility — the follow-up that would contain 2026-08-18-002 | Medium |
| [2026-08-18-019](2026-08-18-019-add-manual-agentbox-sessions-to-herdr.md) | Manual AgentBox sessions in Herdr for interactive isolated work without a pipeline | Low |
| [2026-08-18-003](2026-08-18-003-headless-peer-consult-outside-herdr.md) | Headless peer consult outside herdr was deleted by the launch contract; no replacement is designed | Low |

## 4. herdr-task-sync / label system

Most of this group closed; one cosmetic defect remains.

| Issue | Summary | Severity |
|---|---|---|
| [2026-08-20-012](2026-08-20-012-same-name-repos-defeat-tab-repo-qualification.md) | Two repos sharing a folder basename defeat the multi-repo tab qualifier (never fires, or fires with identical truncated prefixes); cosmetic and bounded | Low |

## 5. Command palette — 16 issues, mostly ideas

The one **bug** is [2026-08-18-024](2026-08-18-024-palette-focus-sleeps-live-trial.md): three sleep-based focus workarounds (plan requirement R5, the only unfinished defect of six); a timing bet that loses on a loaded machine. Medium severity; blocked on a user-side `chezmoi apply` step.

Two more stand out while the rest wait: [2026-08-18-015](2026-08-18-015-palette-verify-dispatched-plugin-action.md) — a `plugin_action` exit code means only "herdr accepted the request", so a failed action is invisible (medium once actions multiply); and [2026-08-18-013](2026-08-18-013-palette-confirm-destructive-commands.md) — confirmation with the cursor on No, a precondition for shipping the built-in command catalog.

The rest are low-severity UX backlog:

| Issue | Summary |
|---|---|
| [2026-08-18-004](2026-08-18-004-palette-frecency-ranking.md) | Rank the resting list by frecency (empty query only) |
| [2026-08-18-005](2026-08-18-005-palette-alias-tier.md) | Strict-prefix alias tier above the fuzzy matcher; core shipped as R10, only the collision rule remains |
| [2026-08-18-006](2026-08-18-006-palette-preview-pane.md) | Preview the selected pane via `herdr pane read` with debounce + TTL cache |
| [2026-08-18-007](2026-08-18-007-palette-pane-and-tab-switcher.md) | Pane and tab switchers; pane focus needs the socket `pane.focus` method |
| [2026-08-18-008](2026-08-18-008-palette-dynamic-plugin-action-source.md) | Surface installed herdr plugins' actions as palette rows |
| [2026-08-18-009](2026-08-18-009-palette-select-options-from-command.md) | `choices_command`: generate `select` options from a shell command |
| [2026-08-18-010](2026-08-18-010-palette-herdr-builtin-command-catalog.md) | Ship a catalog of herdr built-in operations (worktrees, layouts, splits) |
| [2026-08-18-011](2026-08-18-011-palette-query-field-filters.md) | Field filters in the query (`group:git`, `origin:project`), failing closed on typos |
| [2026-08-18-012](2026-08-18-012-palette-jump-back-workspace.md) | Depth-1 MRU: jump back to the previous workspace |
| [2026-08-18-014](2026-08-18-014-palette-percentage-popup-sizing.md) | Percentage popup sizing instead of hardcoded 104×34; `popup` placement has drifted out of CLI help |
| [2026-08-18-016](2026-08-18-016-palette-command-bundles.md) | Command bundles: a directory shipping a command with its own scripts |
| [2026-08-18-017](2026-08-18-017-evaluate-herdr-omnisearch-plugin.md) | Evaluate herdr-omnisearch for pane-content search; blocker: its indexer has been observed scrolling live panes |
| [2026-08-18-023](2026-08-18-023-palette-keyboard-layout-folding.md) | Fold ЙЦУКЕН↔QWERTY so a Cyrillic-layout query matches Latin titles without per-command shortcuts |

## 6. Pi and other environment

| Issue | Summary | Severity |
|---|---|---|
| [2026-08-18-028](2026-08-18-028-create-pi-brew-and-extension-startup-updater.md) | Pi startup updater keeping Homebrew authoritative; the `brew-auto-update` extension referenced by tests suggests this is partly implemented — worth re-scoping or closing | Low |
| [2026-08-19-001](2026-08-19-001-pi-package-inventory-drift.md) | `docs/agent-setup-inventory.md` diverges from actual `pi list`; partly fixed, audit remains | Low |
| [2026-08-18-027](2026-08-18-027-add-herdr-focus-notifications-without-rust-runtime.md) | Clickable blocked/done notifications via `terminal-notifier`, avoiding a Rust build dependency | Low |

## Priority order

1. **Group 1** — restore a trustworthy green/red (`022` and `2026-08-19-001` are concrete, well-diagnosed fixes).
2. **`2026-08-18-002` + `2026-08-18-001`** — the only group with risk beyond code quality.
3. **`2026-08-18-026` + `2026-08-20-009`** — each recurrence costs a paid work leg.
4. Everything palette- and label-related can wait.
