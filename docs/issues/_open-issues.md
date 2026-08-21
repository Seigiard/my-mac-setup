# Open issues — grouped summary

Full snapshot as of 2026-08-21 (evening regeneration): the tables below list all **48** open issues, and that matches `rg -l 'status: open|status: in-progress' docs/issues` (49 hits, one of which is this index file itself). Regenerate this file after closing or filing an issue; it is a derived index, not a source of truth. Whether it should be generated instead of hand-maintained is still undecided — [2026-08-21-013](2026-08-21-013-open-issues-index-is-not-a-full-snapshot.md).

Severity scale:

- **Critical** — breaks the working loop or security right now.
- **High** — has already cost money/time and will recur.
- **Medium** — real risk or noticeable friction.
- **Low** — idea or improvement; nothing breaks without it.

## 1. Broken verification signal (tests and CI) — 16 issues

Until the top rows are fixed, neither CI nor a local pre-push run is a trustworthy green/red.

| Issue                                                                                         | Summary                                                                                                                                                                                                                                                     | Severity     |
| --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| [2026-08-21-004](2026-08-21-004-idempotent-bats-applies-to-the-real-home-directory.md)        | `tests/idempotent.bats` runs `chezmoi apply` with no `--destination`, so a plain `bats tests/idempotent.bats` deploys the checkout over the developer's live dotfiles; observed rewriting `~/.zshenv` mid-session on 2026-08-21                             | **Critical** |
| [2026-08-18-022](2026-08-18-022-install-smithers-dependencies-in-github-ci.md)                | GitHub CI red on main: tests invoke `se flow` without bun and without source-tree smithers `node_modules`                                                                                                                                                   | **Critical** |
| [2026-08-19-001](2026-08-19-001-make-test-ubuntu-fails-two-tests-on-main.md)                  | `make test-ubuntu` fails two tests on main: the Docker harness lacks two setup steps GitHub CI has, so the local suite is not a faithful CI stand-in                                                                                                        | **High**     |
| [2026-08-21-011](2026-08-21-011-pi-brew-test-unresolvable-path-in-docker.md)                  | The Pi brew auto-updater test imports `../home/...`, which does not resolve under the Docker mount layout, so `make test-ubuntu` is red on main                                                                                                             | **High**     |
| [2026-08-21-007](2026-08-21-007-linuxbrew-prefix-unreachable-in-ubuntu-ci-job.md)             | The `test-ubuntu` job installs Homebrew formulae no test can invoke: nothing adds `/home/linuxbrew/.linuxbrew/bin` to `$GITHUB_PATH`. The CI-minimal change shrank the waste; it did not decide whether the job is a config gate or an installability check | Medium       |
| [2026-08-21-005](2026-08-21-005-post-apply-suite-invocation-duplicated.md)                    | The post-apply file list and `--jobs` flags are written out at five sites; dropping a flag at one site silently reverts that runtime to sequential, and a sixth `.bats` file silently goes untested                                                         | Medium       |
| [2026-08-21-014](2026-08-21-014-fail-open-assertions-no-longer-catch-a-slow-fail-open.md)     | Three "fails open promptly" assertions widened 2s → 20s to survive `--jobs` load; they still catch a hang but no longer catch a 3–18s slow fail-open                                                                                                        | Medium       |
| [2026-08-21-018](2026-08-21-018-ci-minimal-docker-apply-has-no-automated-gate.md)             | Nothing automated runs the CI-minimal Docker apply, so a base-image downgrade would break it while every check stays green; `make test-ubuntu` cannot substitute                                                                                            | Medium       |
| [2026-08-20-014](2026-08-20-014-make-test-ubuntu-labeling-drift.md)                           | `make test-ubuntu` maps to the compose service `test-quick` while `CLAUDE.md` calls it "Full test", and `test-quick` runs a full apply despite its "no package installation" comment                                                                        | Low          |
| [2026-08-21-006](2026-08-21-006-ci-sharding-not-evaluated-against-within-file-parallelism.md) | Matrix-sharding the post-apply suite across runners was never written down as a considered option; recorded with its numbers so it need not be re-derived                                                                                                   | Low          |
| [2026-08-21-008](2026-08-21-008-revisit-ci-timeout-minutes-after-minimal-install.md)          | `timeout-minutes` of 15 (ubuntu) and 25 (macOS) were sized against a full Brewfile install; revisit after two weeks of minimal-install runs, keeping the nightly full run's duration as the floor                                                           | Low          |
| [2026-08-21-012](2026-08-21-012-macos-suite-misses-the-60-percent-wall-time-gate.md)          | The parallel post-apply suite lands at 67% of baseline on the macOS CI job against a 60% target; stable, so this is the deferred residual, not a regression                                                                                                 | Low          |
| [2026-08-21-013](2026-08-21-013-open-issues-index-is-not-a-full-snapshot.md)                  | The enumeration in this index was regenerated on 2026-08-21; what stays open is whether a hand-maintained index should exist at all, since only the grouping and severity carry value                                                                       | Low          |
| [2026-08-21-015](2026-08-21-015-capture-the-idle-machine-wall-clock-pattern.md)               | The same idle-machine wall-clock defect has been diagnosed from scratch four times; capture it in `docs/solutions`                                                                                                                                          | Low          |
| [2026-08-21-019](2026-08-21-019-python3-floor-is-stated-in-two-places-with-no-cross-check.md) | The python3 3.9 floor is stated in `tests/helpers/common.bash` and again in `README.md`, with nothing checking the two agree                                                                                                                                | Low          |
| [2026-08-21-023](2026-08-21-023-no-test-observes-which-toml-parser-the-palette-used.md)       | No test observes which TOML parser the palette actually used; the only related test forces the fallback by monkeypatching the import, so an interpreter change (like the one grc's removal caused) flips the branch silently                                | Low          |

## 2. se-pipeline / Smithers — money and lost runs — 6 issues

| Issue                                                                                 | Summary                                                                                                                                                   | Severity |
| ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| [2026-08-18-026](2026-08-18-026-preserve-verification-command-working-directories.md) | The Verification Contract fallback parser drops each command's working directory → false red work gate; a paid work leg was wasted in `run-1787064382632` | **High** |
| [2026-08-20-009](2026-08-20-009-se-simplify-apply-timeout-budget.md)                  | se-simplify apply leg killed at the 20-min `APPLY_TIMEOUT_MS`; the agent spent 12.5 min on unrequested baseline test runs and every edit was reverted     | **High** |
| [2026-08-14-015](2026-08-14-015-run-budgets.md)                                       | `se pipeline` has no budget flag at all; two failed runs burned $16 with no warning and no cap                                                            | Medium   |
| [2026-08-14-020](2026-08-14-020-pipeline-launch-surface.md)                           | Launch surface asks eleven things the operator cannot know; `--until=pr` is advertised and refused; the two flags that matter are hidden                  | Medium   |
| [2026-08-14-008](2026-08-14-008-doc-review-path-has-no-live-coverage.md)              | Verify-doc advisory path mostly proven by a live run; only the P0 waive half remains uncovered                                                            | Low      |
| [2026-08-15-005](2026-08-15-005-se-flow-has-no-main-checkout-escape-diagnosis.md)     | se-flow reports "no content change" instead of naming a main-checkout escape; the doorway that caused it is already closed                                | Low      |

## 3. Child-agent security and reliability — 7 issues

| Issue                                                                               | Summary                                                                                                                                                                                                 | Severity                |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- |
| [2026-08-18-002](2026-08-18-002-sandbox-a-child-agents-filesystem-access.md)        | `"*": "allow"` external-directory read grant applies to every opencode session on the machine, including credential-bearing paths; the sandbox that was the condition for this grant does not exist yet | **Critical** (security) |
| [2026-08-18-001](2026-08-18-001-launch-time-permission-mode-for-child-agents.md)    | A "read-only" child inherits `bypassPermissions` and can still write through its shell; launch-time permission modes were the option not taken                                                          | **High**                |
| [2026-08-18-021](2026-08-18-021-harden-child-agent-ownership-and-launch-cleanup.md) | `herdr-child` enforces no ownership: a parent can target an unrelated live agent; a malformed split response can orphan a pane                                                                          | Medium                  |
| [2026-08-17-001](2026-08-17-001-herdr-event-subscription-supervisor.md)             | A parent loses a hung or crashed child; a supervisor subscribed to `pane_agent_status_changed` would close the gap the callback contract accepts                                                        | Medium                  |
| [2026-08-18-018](2026-08-18-018-run-smithers-pipeline-agents-in-microsandbox.md)    | Upgrade Smithers 0.32 → 0.35 (`smthrs`) and trial a Microsandbox provider with Herdr visibility — the follow-up that would contain 2026-08-18-002                                                       | Medium                  |
| [2026-08-18-019](2026-08-18-019-add-manual-agentbox-sessions-to-herdr.md)           | Manual AgentBox sessions in Herdr for interactive isolated work without a pipeline                                                                                                                      | Low                     |
| [2026-08-18-003](2026-08-18-003-headless-peer-consult-outside-herdr.md)             | Headless peer consult outside herdr was deleted by the launch contract; no replacement is designed                                                                                                      | Low                     |

## 4. herdr-task-sync / label system — 1 issue

Most of this group closed; one cosmetic defect remains.

| Issue                                                                             | Summary                                                                                                                                                 | Severity |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| [2026-08-20-012](2026-08-20-012-same-name-repos-defeat-tab-repo-qualification.md) | Two repos sharing a folder basename defeat the multi-repo tab qualifier (never fires, or fires with identical truncated prefixes); cosmetic and bounded | Low      |

## 5. Command palette — 16 issues, mostly ideas

The one **bug** is [2026-08-18-024](2026-08-18-024-palette-focus-sleeps-live-trial.md): three sleep-based focus workarounds (plan requirement R5, the only unfinished defect of six); a timing bet that loses on a loaded machine. Medium severity; blocked on a user-side `chezmoi apply` step.

Two more stand out while the rest wait: [2026-08-18-015](2026-08-18-015-palette-verify-dispatched-plugin-action.md) — a `plugin_action` exit code means only "herdr accepted the request", so a failed action is invisible (medium once actions multiply); and [2026-08-18-013](2026-08-18-013-palette-confirm-destructive-commands.md) — confirmation with the cursor on No, a precondition for shipping the built-in command catalog.

The rest are low-severity UX backlog:

| Issue                                                                     | Summary                                                                                                        |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| [2026-08-18-004](2026-08-18-004-palette-frecency-ranking.md)              | Rank the resting list by frecency (empty query only)                                                           |
| [2026-08-18-005](2026-08-18-005-palette-alias-tier.md)                    | Strict-prefix alias tier above the fuzzy matcher; core shipped as R10, only the collision rule remains         |
| [2026-08-18-006](2026-08-18-006-palette-preview-pane.md)                  | Preview the selected pane via `herdr pane read` with debounce + TTL cache                                      |
| [2026-08-18-007](2026-08-18-007-palette-pane-and-tab-switcher.md)         | Pane and tab switchers; pane focus needs the socket `pane.focus` method                                        |
| [2026-08-18-008](2026-08-18-008-palette-dynamic-plugin-action-source.md)  | Surface installed herdr plugins' actions as palette rows                                                       |
| [2026-08-18-009](2026-08-18-009-palette-select-options-from-command.md)   | `choices_command`: generate `select` options from a shell command                                              |
| [2026-08-18-010](2026-08-18-010-palette-herdr-builtin-command-catalog.md) | Ship a catalog of herdr built-in operations (worktrees, layouts, splits)                                       |
| [2026-08-18-011](2026-08-18-011-palette-query-field-filters.md)           | Field filters in the query (`group:git`, `origin:project`), failing closed on typos                            |
| [2026-08-18-012](2026-08-18-012-palette-jump-back-workspace.md)           | Depth-1 MRU: jump back to the previous workspace                                                               |
| [2026-08-18-014](2026-08-18-014-palette-percentage-popup-sizing.md)       | Percentage popup sizing instead of hardcoded 104×34; `popup` placement has drifted out of CLI help             |
| [2026-08-18-016](2026-08-18-016-palette-command-bundles.md)               | Command bundles: a directory shipping a command with its own scripts                                           |
| [2026-08-18-017](2026-08-18-017-evaluate-herdr-omnisearch-plugin.md)      | Evaluate herdr-omnisearch for pane-content search; blocker: its indexer has been observed scrolling live panes |
| [2026-08-18-023](2026-08-18-023-palette-keyboard-layout-folding.md)       | Fold ЙЦУКЕН↔QWERTY so a Cyrillic-layout query matches Latin titles without per-command shortcuts               |

## 6. Shell, Pi, and agent config — 2 issues

The eight issues this group held on the morning regeneration were all closed on 2026-08-21 (PRs #31–#38); these two were filed by that work.

| Issue                                                                                  | Summary                                                                                                                                                                                                                                | Severity |
| --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| [2026-08-21-022](2026-08-21-022-brew-auto-update-failures-are-invisible.md)            | The Pi brew auto-updater never surfaces a failure: both call sites discard the failed result and `setStatus` is never called, so even a manual `/brew-auto-update-now` reports nothing when Homebrew or `pi update --extensions` breaks | Medium   |
| [2026-08-21-020](2026-08-21-020-pi-skills-and-agents-inventory-drift.md)               | The inventory doc's Pi skills/agents subsections list `web-research` and nine "authored, keep" agents that no longer exist on disk or in the repo; the doc lines may be the only surviving record, so deletion needs a decision         | Low      |

## Priority order

1. **`2026-08-21-004`** — the test suite overwrites the developer's live dotfiles; the only issue here that can destroy uncommitted work.
2. **Group 1's remaining top rows** — `2026-08-18-022`, `2026-08-19-001`, `2026-08-21-011` restore a trustworthy green/red and are concrete, well-diagnosed fixes.
3. **`2026-08-18-002` + `2026-08-18-001`** — the only group with risk beyond code quality.
4. **`2026-08-18-026` + `2026-08-20-009`** — each recurrence costs a paid work leg.
5. Everything palette- and label-related can wait.
