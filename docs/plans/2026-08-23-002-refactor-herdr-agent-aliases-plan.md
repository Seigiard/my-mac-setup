---
title: Herdr agent aliases and presentation cutover - Plan
date: 2026-08-23
deepened: 2026-08-24
type: refactor
topic: herdr-agent-aliases
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-dialogue
execution: code
---

# Herdr agent aliases and presentation cutover - Plan

## Goal Capsule

- **Objective:** replace semantic task names with locally generated `color-animal` aliases for every live Herdr agent while pool capacity remains, use the registered alias as the identity shown in panes and tabs, and let interrupted activation converge on a later apply.
- **Product authority:** the Product Contract below, the user's confirmed all-agent scope on 2026-08-23, and the eventual-convergence scope reduction confirmed on 2026-08-24.
- **Superseded behavior:** the LLM-generated task naming contract in `docs/plans/2026-08-10-001-feat-herdr-task-sync-plan.md`; the pane-label task-slug portions of later presentation plans.
- **Preserved behavior:** runtime prefixes, process and idle labels, tab composition, Git/worktree metadata, complete-snapshot reconciliation, the sweep daemon, and the existing child callback protocol.
- **Execution profile:** retain the completed alias cutover, add one activation-retry guard, and pin the callback-alias instructions in source and deployment tests.
- **Open blockers:** none.
- **Stop conditions:** stop implementation if `herdr agent rename <pane-id> <alias>` cannot assign an addressable registered name, if Herdr 0.8.2 does not return the structured `agent_name_taken` conflict code, or if live records do not expose the required pane, runtime, terminal, revision, and state-sequence fields. Do not invent a second identity registry.

## Product Contract

### Problem Frame

Semantic task names require agent-specific prompt hooks, transcript parsing, detached model calls, mutable task state, and race reconciliation. That machinery is expensive and still gives panes unstable names. Herdr already has a live agent registry and unique agent names. A short local alias such as `yellow-falcon` can serve as the registered address and the visible identity without reading prompts or calling a model.

The desired surface is intentionally mechanical:

| Surface | Grammar |
|---|---|
| Registered Herdr agent name | `<color>-<animal>` |
| Pane label | `<runtime-prefix>:<color>-<animal>` |
| Tab label | ordered pane labels joined with ` · `; all-idle tabs retain `~ <tab-index>` |
| Agent sidebar | state icon, workspace, and pane label only; no Git location row |
| Child start result | `{"agent":"<color>-<animal>","pane":"<pane-id>"}` |

Runtime prefixes remain `cc` for Claude Code, `oc` for OpenCode, `pi` for Pi, and `cx` for Codex. Unknown runtimes retain the current lowercase-first-letter fallback rather than blocking alias assignment.

Product Contract preservation: R2-R6 and R8-R11 are unchanged; R1, R7, R12, and R13 are tightened without changing their user-facing intent; R14 adds the bounded activation-retry guarantee.

### Requirements

**Alias identity**

- R1. While the repository-owned pool has capacity, every live agent represented by exactly one complete Herdr agent record receives a locally generated alias matching `^[a-z]+-[a-z]+$` and Herdr's 32-character name limit. Exhaustion follows AE8's bounded fail-closed behavior rather than claiming impossible convergence.
- R2. The alias is the registered Herdr agent name, not presentation-only metadata. Commands that accept an agent name can address the agent by that alias.
- R3. A registered name that is already a member of this repository's alias pool remains unchanged across events, sweeps, daemon restarts, pane moves, and process-state changes.
- R4. A semantic, tracker-derived, manual, or otherwise non-pool registered name is controller-owned and is replaced on the next successful reconciliation pass. A manual rename to another valid pool alias is preserved if it remains unique, but manual renaming of an active child is not transparent: launch-time alias-plus-pane operations fail safe when pair verification detects staleness, and only a freshly verified callback alias for the launch pane may replace that identity for later reply and reap.
- R5. Alias generation is local, bounded, Bash 3.2-compatible, and independent of prompts, transcripts, models, networks, and agent-specific adapters.

**Presentation**

- R6. Agent panes render `<runtime-prefix>:<alias>`. Process panes retain the current foreground-process label, idle panes retain `~`, and tabs retain the current ordered pane-label composition.
- R7. Git/worktree resolution and `$git_ref` metadata remain unchanged for integrations, but no Git token renders in pane labels, tab labels, or the agent sidebar. Alias assignment must not weaken location metadata, process truncation, external-label repair, or idempotency. Retained stale-location evidence applies only while both pane ID and terminal ID still identify the same pane occupant; a terminal mismatch clears presentation-owned stale evidence instead of attaching another pane's Git identity.
- R8. Herdr lifecycle event payloads remain invalidation signals only. Every event and sweep derives intent from a fresh complete snapshot.

**Launch and cleanup**

- R9. `herdr-child start` no longer accepts `--name`. It allocates an alias before registration, starts the child under that name, injects the same name into `HERDR_CHILD_NAME`, and returns the registered alias plus pane ID.
- R10. `ask-in-herdr` and other callers or wrappers of `herdr-child` do not list agents or synthesize names. Only `herdr-child` and the presentation reconciler query the live registry for allocation. Callers consume the alias and pane returned by `herdr-child` for read, status, reply, and reap operations.
- R11. Claude Code, OpenCode, and Pi semantic task adapters, prompt/model execution, transcript parsing, task metadata publication, task state, and their deployed files are removed. Herdr's own agent-state integrations remain untouched.
- R12. Deployment freezes the old adapter entry, disables the plugin, and drains the known old sweep daemon and workers before managed files change. Temporary label drift during an interrupted cutover is acceptable because the new sweep daemon reconciles every complete snapshot after activation.
- R13. `reply` and `reap` require the alias-plus-pane pair returned at launch or reported by a child callback. The parent stores the launch pane, accepts that the callback alias may differ from the launch alias, verifies the callback alias against that pane, and uses the verified pair for reply and reap. This is stale-target validation rather than caller authentication. Herdr 0.8.2 has no atomic compare-and-prompt or compare-and-close operation, so the final same-pane replacement interval remains an explicit residual risk rather than a false absolute guarantee.

**Cutover retry**

- R14. If the before-script created a cutover transaction and `herdr` is unavailable during activation, the after-script exits non-zero and leaves the transaction pending. A later apply retries activation. Missing `herdr` remains a successful no-op when no transaction exists.

### Acceptance Examples

- AE1. Given three live agents named `review-auth`, `CORE-42`, and `consult-pi-123`, one successful pass registers three distinct pool aliases and renders labels such as `cc:yellow-falcon`, `oc:red-bear`, and `pi:blue-otter`.
- AE2. Given a live agent already registered as a valid pool alias, repeated events and sweeps issue no agent rename and preserve the same pane, tab, and sidebar identity. Git-only location changes update metadata without changing those surfaces.
- AE3. Given two allocators choose the same first candidate concurrently, Herdr accepts only one registration; the loser refreshes live state and chooses another candidate. Collision cleanup closes only a still-agent-free pane with the captured terminal identity; ambiguous cleanup preserves the pane and reports it instead of risking another agent.
- AE4. Given an agent exits or is replaced before the final pre-rename validation, the pass skips it. Given replacement occurs in Herdr 0.8.2's unavoidable interval between validation and rename, the replacement may receive the candidate intended for its predecessor; this is acceptable because aliases carry no semantic ownership and the resulting live state already satisfies R1-R6.
- AE5. Given an incomplete or contradictory snapshot, the pass performs no new presentation writes and leaves existing labels and location state intact. A later complete snapshot converges once.
- AE6. Given `herdr-child start --kind opencode --prompt-file ...`, the command returns the generated alias and pane ID, and the child's environment and initial prompt use that launch alias. The callback marker resolves the alias current for the launch pane; parent reply validation and the reap hint use that freshly verified callback pair.
- AE7. Given the old task-sync adapters, cache records, and live `task` tokens exist at deployment time, old workers are drained, every live `task` token is cleared under source `task-sync`, no adapter invokes the retired engine, and no naming model restarts.
- AE8. Given all aliases are occupied at the initial read, allocation terminates before child pane creation. Given the last free alias is lost after a child pane is split, the child closes that exact pane, performs no second split, and exits non-zero. Reconciliation skips the whole presentation pass because a tab cannot satisfy R6 while one agent lacks an alias.
- AE9. Given child A's alias is later reused by child B in another pane, a delayed reply or reap carrying A's alias-plus-pane pair rejects the mismatch and never targets or closes B.
- AE10. Given the before phase created a transaction and `herdr` disappears before the after phase, the after-script exits non-zero, leaves `phase=deployed` pending, and completes activation on a later apply after `herdr` returns. Given no transaction and no `herdr`, a first installation exits successfully.
- AE11. Given a child callback reports a current alias different from its launch alias, the parent verifies that callback alias against the launch pane and uses it for both reply and reap.

### Scope Boundaries

- Do not add `$ham Ask`, SSH routing, `ask_agent`, `ask_parent`, or any messaging protocol.
- Do not add a durable parent-child registry. The current launch-time parent pane and alias-plus-pane callback contract remain as-is; pane-renumber-safe relationship routing is separate work.
- Do not preserve semantic task names as labels, metadata, aliases, or migration fallback.
- Do not keep compatibility shims for the retired `herdr-task-sync --agent`, `--session`, `--transcript`, `--set`, or worker interfaces.
- Do not copy source code, word lists, comments, or tests from `zerodice0/herdr-agent-labels`. That repository had no license at researched commit `f26d8e460b788cfb5a73b6e828c5e4b7acc75296`; it is product prior art only.
- Do not run `chezmoi apply` on the host. The user performs the live deployment after the repository change is committed and synced into chezmoi's separate source clone.
- Do not rewrite historical plans, resolved issues, or solution records merely because they mention `herdr-task-sync`. Update only active managed configuration, current operational skills/contracts, tests, and this superseding plan.
- Do not add a generic concurrent-cutover lock. Normal `chezmoi apply` operations serialize through chezmoi's persistent-state writer lock; the cutover transaction protects its own crash/retry lifecycle.
- Do not preserve a manually disabled `seigi.pane-labels` state during rollback. KTD11 intentionally restores the operational pre-cutover writer by re-enabling the plugin and verified daemons.
- Do not require callback aliases to belong to the generated pool. Pair validation prevents stale cross-pane targeting; pool membership is presentation policy, not callback authentication.
- Do not merge the consumer-specific snapshot and agent-list validators into one abstraction. Share malformed fixture coverage for common invariants instead.
- Do not rewrite the quadratic `jq` joins before evidence shows sessions approaching hundreds of panes. The measured cost is negligible at the documented 20-pane scale.
- Do not add a new process-incarnation format, command-family census, engine-side writer fence, socket ledger, migration preimage journal, or six-phase transaction state machine. Temporary naming drift is acceptable; the next successful sweep provides eventual convergence.

### Verified CLI Contracts

- Local binary: `herdr 0.8.2` on 2026-08-23.
- `herdr agent rename <TARGET> <NAME>|--clear` accepts a target that the CLI resolves as a live name or pane ID; it exposes no expected-revision or compare-and-swap option.
- `herdr agent start <NAME> --kind <KIND> --pane <ID>` registers the requested name and returns structured failures.
- `herdr pane report-metadata <PANE_ID> --source <ID> --clear-token <NAME> --seq <N>` provides the source-scoped live task-token cleanup used by KTD9.
- `herdr plugin disable <PLUGIN_ID>` provides the quiescence entry point used by KTD11.
- `herdr session list --json` exposes each running session's `socket_path`; link, enable, and reload do not rerun startup hooks for already-running sessions, so the after-script must call ensure explicitly per socket.
- `herdr session list --json` does not enumerate arbitrary servers launched only through a custom `HERDR_SOCKET_PATH`. Valid cache records, the current environment, and the transaction ledger are additional socket evidence.
- Herdr stores plugin enabled state globally in `plugins.json`; `herdr plugin link` enables by default unless passed `--disabled`. Rollback re-enables the old plugin by contract rather than restoring a per-session state that does not exist.
- Herdr injects `HERDR_SOCKET_PATH` into plugin command environments, but `ps ... -o command=` does not expose it. A daemon record must carry socket identity explicitly.
- Public pane IDs are monotonic within one workspace lifetime but can repeat after a new server or workspace starts at the same socket, so persistent location evidence also binds terminal identity.
- A live auto-detected record currently exposes `agent`, `pane_id`, `terminal_id`, `revision`, and `state_change_seq`; `agent_session` can be absent and a registered `name` is absent before explicit naming.

## Planning Contract

### Key Technical Decisions

- KTD1. **Rename the remaining engine to `herdr-pane-labels`.** The presentation coordinator becomes `home/dot_local/bin/executable_herdr-pane-labels`; `ensure.sh`, `sweep.sh`, tests, comments, and operational commands use the new name. The old executable is deleted and listed in `.chezmoiremove`. This avoids leaving a task-oriented public interface around presentation-only behavior.
- KTD2. **Use one shared repository-authored alias library.** `home/dot_local/lib/herdr-aliases.sh` owns the color list, animal list, pool validation, alias validation, and candidate traversal. Both `herdr-pane-labels` and `herdr-child` source it by a script-relative path. A test-only seed override makes candidate order reproducible without creating persisted alias state.
- KTD3. **Use a bounded full-pool traversal, not random retries.** Hash an allocation seed with a ubiquitous local primitive such as `cksum`, map it to a start offset in the Cartesian color-animal pool, then visit every candidate once in wraparound order. The seed includes the current Herdr socket identity plus stable live identity fields; child allocation also includes the launching process and current sequence. Herdr's live registry, not the hash or a preflight list, is the final uniqueness authority.
- KTD4. **Treat the registered alias as the only durable alias state.** No alias cache or semantic mapping is persisted. A valid current pool alias is preserved. A non-pool name is assigned from candidates absent from the latest live set. This makes restart and event behavior naturally idempotent.
- KTD5. **Revalidate before every agent rename and verify after mutation.** A complete live agent record requires string `pane_id`, `agent`, and `terminal_id`, plus numeric `revision` and `state_change_seq`; `name` and `agent_session` are optional because auto-detected agents may be unnamed and native session IDs may be absent. Immediately before `herdr agent rename`, re-read and compare pane ID, runtime, terminal ID, revision, state sequence, current name when present, and native session when present. Target by pane ID. After success, require a fresh complete record with the accepted alias and a valid current join before any pane, tab, or metadata write. Herdr 0.8.2 has no compare-and-swap rename. A same-pane replacement in the final command interval may receive the alias; because aliases are deliberately non-semantic and address the current live occupant, this is a valid converged outcome rather than stale task identity.
- KTD6. **Classify concurrency with structured errors plus live state.** Retry allocation only when the failed command returns exact code `agent_name_taken` and a fresh complete registry confirms another target owns the candidate. Keep exact `agent_pane_busy` retries within the same child pane. A generic failure followed by unrelated candidate occupation is still a generic failure. Malformed responses, unavailable state, or any other code abort that target safely.
- KTD7. **Keep child callback state internally consistent by retrying the whole pane allocation.** `herdr-child` chooses the candidate before `pane split` because `HERDR_CHILD_NAME` is injected at split time. Capture the split pane's terminal identity. If registration returns `agent_name_taken`, re-read the pane and close it only when that terminal identity is unchanged and no agent occupies it; ambiguity preserves the pane and aborts with a cleanup warning. After confirmed close, choose the next candidate and repeat split plus start. If the refreshed pool is exhausted, do not split again. Existing `agent_pane_busy` readiness retries remain inside one pane. Any non-conflict failure cleans up under the same safe-close rule and exits.
- KTD8. **Require a complete agent join before presentation writes.** A usable snapshot has arrays for panes, tabs, and agents; every agent-bearing pane joins by pane ID to exactly one record satisfying KTD5; no two records share a pane or terminal; and joined pane, tab, workspace, runtime, and terminal fields do not contradict each other. Any missing field, wrong type, duplicate, contradiction, malformed response, or complete-but-stale post-rename record aborts the whole presentation pass. Existing labels and retained location state remain untouched until a complete pass.
- KTD9. **Perform a selective presentation-state cutover.** The new engine uses `~/.cache/herdr-pane-labels` and presentation-only environment overrides. During quiescence, copy only validated per-socket `socket.state`, terminal-bound per-pane `location.state`, and the location high-water/retained-location fields needed for stale Git behavior. Legacy location evidence receives a terminal ID only from an exact complete live join. Do not migrate task prompts, transcript state, model claims, task metadata high-water marks, task inboxes, or worker claims. After all old workers stop, clear each live pane's old token with the deliberately unsequenced `herdr pane report-metadata <pane> --source task-sync --clear-token task`; Herdr 0.8.2 accepts this same-source clear after sequenced writes, and the migration verifies disappearance from a fresh read.
- KTD10. **Keep the prior art boundary explicit.** The implementation uses the independently selected `color-animal` product shape and a generic Cartesian allocator. Repository authors create all vocabulary and code from scratch, validate every word against the local grammar, and record no HAM-derived word-by-word correspondence.
- KTD11. **Use the existing before/after cutover barrier.** The before-script installs the reversible no-op at the old engine path, disables the plugin, drains known owners, migrates validated location evidence, and leaves a transaction for the after-script. The after-script marks managed deployment, relinks and enables the plugin, ensures running sockets, and commits only after verification. If `herdr` is unavailable while that transaction exists, activation fails without recording success and retries on a later apply.
- KTD12. **Make child operations pair-addressed.** `reply` keeps `--to <alias> --pane <pane>`. Change `reap` from name-only/multi-name selection to one `--to <alias> --pane <pane>` operation with a fresh pair and terminal-identity check immediately before close. A child `ask` resolves the current alias for its current pane before emitting the callback marker, so a valid manual alias rename does not make the marker stale; launch-time environment remains initial evidence only. `ask-in-herdr` captures read/status output, validates the alias-plus-pane pair both before and after capture, and prints the output only after the second validation. Same-pane replacement after the final check remains the documented Herdr limitation.
- KTD13. **Prefer eventual convergence over a stronger takeover protocol.** Keep the existing transaction format and owner checks. Do not add new writer fencing or rollback metadata. An interrupted activation remains visible as a failed apply, and the next apply plus normal sweep repairs aliases and labels.

### Convergence Model

The cutover is not a zero-downtime ownership transfer. The before-script best-effort stops the old engine and the after-script starts the new engine. If activation cannot run, chezmoi reports failure and retains the existing transaction. A later apply retries activation; once the new sweep daemon runs, its fresh snapshot replaces temporary semantic or stale labels with registered aliases.

### Risks and Dependencies

- Herdr is pinned to 0.8.2 for these contracts. A schema or plugin-lifecycle change requires revalidating structured conflict codes, global plugin state, socket discovery, and startup-hook behavior before implementation.
- Temporary aliases or labels can remain stale between an interrupted activation and the next successful apply or sweep. This is accepted by the eventual-convergence contract.
- Alias-plus-pane values are coordination data, not credentials. This work rejects detected pair mismatches and cross-pane alias reuse, but it cannot identify a same-pane replacement and does not add caller authentication or parent ownership enforcement.
- Concurrency tests use explicit hooks, marker files, and release barriers. Wall-clock bounds are hang guards only and must not be the proof of ordering or quiescence.

### Failure Defaults

| Scenario | Required default |
|---|---|
| Snapshot is incomplete | Perform no alias, pane, or tab rename; retry on the next invalidation or sweep. |
| Target changed before rename | Skip that target. A replacement in the unavoidable final command interval may receive the candidate and is valid because aliases have no semantic ownership. |
| Command returns `agent_name_taken` and candidate is live elsewhere | Refresh live state and continue the bounded candidate traversal. |
| Rename/start failed for an unclassified reason | Stop that target; child launch applies KTD7's safe-close rule and returns non-zero. Preserve an ambiguous pane and report a cleanup warning. |
| Alias pool is exhausted | Terminate without looping and skip the whole presentation pass; initial child exhaustion creates no pane. |
| Manual non-pool rename | Replace it on the next complete sweep. |
| Manual valid-pool rename | Preserve it if unique. |
| Old daemon or worker PID cannot be verified | Abort the before-script and the apply before managed files change. |
| Live registered non-pool name exists before cutover | Abort and require the user to drain that legacy child or clear the explicit name before retrying apply. |
| `herdr` is missing and no transaction exists | Exit successfully because there is no activation to finish. |
| `herdr` is missing while a transaction exists | Exit non-zero, retain the transaction, and retry after restoring `herdr`. |
| Apply is interrupted after the old engine stops | Accept temporary label drift; rerun apply and let the new sweep converge. |

## Implementation Units

### U1. Add the shared alias allocator

- **Goal:** provide one deterministic, bounded, independently authored alias vocabulary and candidate traversal for every repository-owned registration path.
- **Requirements:** R1, R3-R5. Implements KTD2-KTD4 and KTD10.
- **Dependencies:** none.
- **Files:** `home/dot_local/lib/herdr-aliases.sh` (new), `tests/scripts.bats`, `tests/smoke.bats`.
- **Approach:** define lowercase ASCII color and animal arrays whose Cartesian product contains at least 1,024 unique names and whose longest combination fits Herdr's limit. Expose functions to validate the pool, test whether a name belongs to it, and emit each candidate exactly once from a seed-derived offset. Keep the library free of Herdr calls so callers remain responsible for current occupancy and registration.
- **Test scenarios:** library parses under system Bash; every word and combination matches the grammar; all combinations are unique and at most 32 characters; the pool meets the minimum size; a fixed seed yields a stable full sequence with no repetition; wraparound reaches the last free alias; all-occupied traversal terminates; no network, `pi`, or `claude` binary is consulted; the managed library deploys under `~/.local/lib/`.
- **Verification:** focused alias tests in `tests/scripts.bats` pass and `make lint` reports no Bash 3.2 incompatibility.

### U2. Replace task sync with alias-aware presentation reconciliation

- **Goal:** make one presentation-only engine own agent aliases, pane labels, tab labels, sidebar identity, and existing location metadata.
- **Requirements:** R1-R8. Implements KTD1 and KTD3-KTD9.
- **Dependencies:** U1.
- **Files:** `home/dot_local/bin/executable_herdr-task-sync` (delete), `home/dot_local/bin/executable_herdr-pane-labels` (new from the retained presentation code), `home/private_dot_config/herdr/plugins/herdr-pane-labels/ensure.sh`, `home/private_dot_config/herdr/plugins/herdr-pane-labels/sweep.sh`, `home/private_dot_config/herdr/plugins/herdr-pane-labels/herdr-plugin.toml`, `home/private_dot_config/herdr/config.toml`, `tests/helpers/herdr_task_sync.bash` (replace with `tests/helpers/herdr_pane_labels.bash`), `tests/herdr_task_sync_descriptor_probe.bats` (replace with `tests/herdr_pane_labels_descriptor_probe.bats`), `tests/scripts.bats`.
- **Approach:** remove the prompt CLI, detached naming worker, model chain, transcript parser, slug normalization, task inbox, task claims, task metadata publication, semantic session state, and task pruning. Retain the snapshot coordinator, location resolver, process/idle formatter, intent comparison, final guards, socket serialization, and sweep loop under presentation-only names. Join each agent pane to its live agent record, preserve or allocate its registered alias, and refresh before composing `<prefix>:<alias>` pane labels and ordered tabs. Keep Git location as pane metadata while rendering only state, workspace, and pane identity in the agent sidebar.
- **Test scenarios:** known and unknown runtime prefixes; existing valid alias stays stable across restart and sweep; semantic/tracker/manual non-pool names converge; exact `agent_name_taken` chooses another alias while generic failure does not; agent exits, moves, or is replaced before rename; same-pane replacement in the final non-atomic interval receives a valid alias and produces current pane/tab intent; missing required field, wrong type, duplicate pane/terminal, contradictory join, malformed response, and complete-but-stale post-rename snapshot each abort the pass; complete follow-up snapshot converges; process, idle, tab-order, external repair, Git/worktree metadata, names-only sidebar, detached HEAD, migrated first-pass stale location, UTF-8 icon, truncation, and idempotency regressions remain green; no task token or model process is produced.
- **Verification:** `bash -n` passes for the new engine, the focused presentation tests pass, and repeated sweeps record no writes after convergence.

### U3. Make child and peer-consult names allocator-owned

- **Goal:** ensure repository-owned child agents start directly with aliases and preserve the existing callback contract.
- **Requirements:** R1-R5, R9, R10, R13. Implements KTD2, KTD3, KTD6, KTD7, and KTD12.
- **Dependencies:** U1.
- **Files:** `home/dot_local/bin/executable_herdr-child`, `home/private_dot_claude/skills/ask-in-herdr/scripts/ask.sh`, `home/private_dot_claude/shared/child-agent-contract.md`, `home/private_dot_claude/skills/herdr/SKILL.md`, `tests/scripts.bats`, `tests/smoke.bats`.
- **Approach:** remove `--name` from `herdr-child start`, allocate internally, and keep `HERDR_CHILD_NAME`, the initial prompt identity, and return JSON aligned to the accepted launch alias. Resolve the current alias from the current pane before emitting a callback marker. Preserve alias-plus-pane validation for reply, and require the same pair for reap immediately before close. On exact registration collision, close the split pane and retry the entire allocation with the next candidate. Remove consult-specific `consult-$AGENT-$$` synthesis and preflight listing from `ask.sh`; parse and use the returned alias plus pane in every later command and hint.
- **Test scenarios:** help and invalid-option behavior reject `--name`; successful starts for Claude Code, OpenCode, and Pi return a pool alias; child environment, initial prompt, and result agree; same-first-candidate concurrent starts produce distinct aliases; initially exhausted pool performs no split; last-free race performs one split, one exact collision, one safe close, and no second split; another agent or changed terminal before cleanup preserves the pane and aborts with a warning; `agent_pane_busy` reuses one pane; generic failure followed by unrelated occupation does not retry; timeout 124 still returns alias plus pane; callback marker uses the current alias for its pane; reply and reap validate alias plus pane and terminal; cross-pane alias reuse is never closed by a stale reap; ask-in-herdr does no name preflight, buffers read/status output, and discards it when either pair validation fails.
- **Verification:** the focused `herdr-child` and `ask-in-herdr` sections of `tests/scripts.bats` pass.

### U4. Remove semantic adapters and deployed remnants

- **Goal:** leave no prompt-driven semantic naming path or deployed compatibility file.
- **Requirements:** R11. Implements KTD1 and KTD9.
- **Dependencies:** U2.
- **Files:** `home/private_dot_claude/hooks/executable_herdr-task-sync-hook.sh` (delete), `home/private_dot_config/opencode/plugins/herdr-task-sync.ts` (delete), `home/dot_pi/agent/extensions/herdr-task-sync.ts` (delete), `home/private_dot_claude/private_settings.json.tmpl`, `home/.chezmoiremove`, `tests/herdr_task_sync_descriptor_probe.bats` (rename/replace per U2), `tests/scripts.bats`, `tests/smoke.bats`, `tests/templates.bats`, `home/private_dot_claude/skills/herdr/SKILL.md`, and `home/private_dot_claude/shared/child-agent-contract.md`.
- **Approach:** remove only the custom task-sync hook entries from Claude settings while preserving Herdr's native agent-state hooks. Add `.chezmoiremove` entries for the old executable and all three deployed adapters. Replace active task-slug comments and usage examples with alias terminology. Remove obsolete model environment settings, transcript fixtures, worker timing tests, task-state helpers, and assertions; do not retain dead compatibility branches or rewrite historical artifacts.
- **Test scenarios:** rendered Claude settings have no task-sync command while native agent-state hooks remain; deployed Claude, OpenCode, and Pi task adapters are absent; old executable is absent; no managed source invokes `herdr-task-sync --agent`, `pi -p`, `claude -p`, prompt parsing, or `$task` publication; the new engine and alias library deploy; current Herdr integration files remain present.
- **Verification:** `make test-templates`, source-level assertions in `tests/scripts.bats`, the retired-interface search, and `make test-ubuntu` pass. Direct `bats tests/smoke.bats` on the host is not a checkout verification because it reads the deployed home.

### U5. Drain known old writers and verify the full contract

- **Goal:** best-effort drain known old presentation writers before enabling the new engine, then rely on complete-snapshot sweeps for eventual repair.
- **Requirements:** R6-R8, R11, R12. Implements KTD1, KTD8, KTD9, and KTD11.
- **Dependencies:** U2, U4.
- **Files:** `home/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh` (new shared shell body), `home/.chezmoiscripts/run_onchange_before_6-quiesce-herdr-pane-labels.sh.tmpl` (new), `home/.chezmoiscripts/run_onchange_after_6-link-herdr-pane-labels.sh.tmpl`, `home/private_dot_config/herdr/plugins/herdr-pane-labels/ensure.sh`, `tests/scripts.bats`, `tests/smoke.bats`.
- **Approach:** put the new engine, alias library, manifest, and wrappers in both scripts' hash inputs. The before-script creates the authoritative transaction and installs recovery traps before it installs the reversible no-op at the old engine path, disables the plugin, checks that no live registered non-pool name can be a legacy child, and drains old/current cache owners to a fixed point using KTD11's verification rules. Any unverifiable or surviving owner restores the old executable/plugin and aborts before managed deployment. It then migrates only validated location evidence and clears live `task` tokens with unsequenced `--source task-sync --clear-token task`, verifying disappearance from a fresh live read. The after-script repeats the owner scan before enabling, relinks/enables/reloads, explicitly ensures each running socket from `herdr session list --json`, and verifies one new daemon per socket.
- **Test scenarios:** an adapter invocation after initial drain reaches the no-op and starts no worker; pre-existing registered non-pool child blocks cutover with rollback; rollback restores the old executable, re-enables the plugin, explicitly ensures every socket discovered by the existing cutover machinery, and verifies old daemons; plugin disable precedes process signaling; verified old daemon and in-flight presentation/naming workers receive `TERM` and drain before file replacement; an event during quiescence starts no writer; stale locks recover; legacy PID verification double-checks exact command/start time; unrelated or unverifiable live PID rolls back and aborts; location-only state migrates while task state and claims do not; every task clear is unsequenced and a fresh read confirms absence; second drain catches a late old process; session-list sockets receive explicit ensure calls and independent locks; a second apply replaces current-cache daemon PIDs after engine change; complete first pass assigns aliases and repairs pane/tab labels.
- **Verification:** focused daemon tests, smoke deployment, lint, and the Docker apply suite pass. Live verification remains user-driven after chezmoi sync/apply.

### U6. Keep strict ownership hardening out of scope

- **Goal:** avoid adding machinery that the eventual-convergence product contract does not need.
- **Requirements:** R12. Implements KTD13.
- **Dependencies:** U5.
- **Files:** none.
- **Approach:** retain the current owner records, quiescence checks, transaction shape, location handling, and per-sweep pool behavior. Do not add process-incarnation proofs, a writer census, mutation fences, a socket ledger, preimage journals, or pool caching.
- **Verification:** the implementation diff contains none of those new mechanisms.

### U7. Retry interrupted activation

- **Goal:** prevent a missing `herdr` binary from turning a pending activation into a successful apply.
- **Requirements:** R14. Implements KTD11 and KTD13.
- **Dependencies:** U5.
- **Files:** `home/.chezmoiscripts/run_onchange_after_6-link-herdr-pane-labels.sh.tmpl`, `tests/scripts.bats`.
- **Approach:** after marking the managed child deployed, distinguish a clean no-transaction install from an active cutover transaction. Keep the existing successful skip for the former. Exit non-zero with the transaction untouched for the latter so the next apply retries plugin activation.
- **Test scenarios:** missing `herdr` with no transaction exits zero; missing `herdr` after before/deploy exits non-zero, reports pending activation, retains `phase=deployed`, and does not print the clean-install skip message; a later normal after-run commits.
- **Verification:** focused cutover tests pass.

### U8. Pin the callback-alias contract in source and deployment tests

- **Goal:** prevent operational instructions from reverting to the stale launch alias after a child reports a current callback alias.
- **Requirements:** R13. Implements KTD12.
- **Dependencies:** U3.
- **Files:** `home/private_dot_claude/skills/herdr/SKILL.md`, `tests/scripts.bats`, `tests/smoke.bats`.
- **Approach:** keep the corrected instructions that store the launch pane, verify the callback alias against it, and use the verified alias for reply and reap. Add source-level and disposable-deployment assertions instead of relying only on executable behavior tests.
- **Test scenarios:** source and deployed instructions allow callback alias to differ from launch alias; both require verification against the launch pane; reply and reap use the verified callback alias plus pane; alias-only, launch-alias-only, and pool-membership-as-authentication wording fail the contract test.
- **Verification:** focused source assertions and the Docker-deployed smoke test pass.

## Sequencing and Commit Boundaries

1. **Completed baseline:** U1-U5 are the already-landed alias allocator, presentation engine, child contract, semantic-adapter removal, and initial cutover barrier. Retain their tests and do not repeat their implementation.
2. **Convergence follow-up:** U6 records the rejected strict-hardening scope. Implement U7 and U8 as one small follow-up.
3. **Full verification:** run every gate against the resulting cutover. Deleted semantic code stays deleted.

Each implementation batch is gated on its focused tests before the next batch. The final boundary must contain the clean cutover rather than a compatibility period where old adapters can call the new engine.

## Verification Contract

| Command | Covers | Done signal |
|---|---|---|
| `bash -n home/dot_local/lib/herdr-aliases.sh home/dot_local/bin/executable_herdr-pane-labels home/dot_local/bin/executable_herdr-child home/private_dot_claude/skills/ask-in-herdr/scripts/ask.sh` | U1-U3 | The shared library and all Bash entry points parse under the system shell. |
| `bats tests/scripts.bats` | U1-U8 | Allocator, reconciliation, retired-interface, callback, activation-retry, migration, and daemon scenarios pass. |
| `make test-templates` | U4, U7 | Claude settings render without task-sync hooks, and the cutover scripts render with complete hash inputs. |
| `make lint` | U1-U8 | Shellcheck passes with Bash 3.2-compatible code. |
| `make test-local` | U1-U8 | Chezmoi dry-run shows only the intended managed cutover changes. |
| `make test-ubuntu` | U1-U8 | A disposable apply, activation-retry fixture, idempotency checks, and the full Linux suite pass against this checkout with no silently skipped applicable checks. |
| `git diff --check` | U1-U8 | The complete plan and implementation diff contains no whitespace errors. |
| `rg -n 'herdr-task-sync|HERDR_TASK_SYNC|task-sync-hook|\$task' home --glob '!home/.chezmoiremove' --glob '!home/.chezmoiscripts/run_onchange_before_6-quiesce-herdr-pane-labels.sh.tmpl' --glob '!home/.chezmoitemplates/herdr-pane-labels-cutover-lib.sh'` | U4 | No retired semantic interface remains outside the explicit removal list and bounded cutover migration library; focused U5 tests constrain those intentional references. |

`make test-suite` is not sufficient for this managed-file change because it reads the already-deployed home directory instead of applying `home/` from this checkout.

## Rollout Contract

1. Commit the repository change and sync it into `~/.local/share/chezmoi`.
2. Before apply, inspect `herdr agent list` and drain any explicitly named non-pool child; the before-script enforces this and prints the blocking alias plus pane.
3. The user runs `chezmoi apply`; the agent does not run it on the host. If the apply fails, restore the reported prerequisite and rerun it.
4. The before/after scripts freeze the old adapter entry, disable and drain the old plugin, migrate location-only state, clear old task tokens, deploy, relink, and activate the new plugin.
5. If activation is interrupted or `herdr` is temporarily unavailable, leave `cutover-rollback` in place and rerun apply. The next successful sweep repairs any temporary naming drift.
6. Verify every socket discovered by the existing cutover machinery has a new daemon, `herdr agent list` contains pool aliases, pane labels use runtime prefixes plus those aliases, tabs join the resulting pane labels, and the agent sidebar contains no Git location row.
7. Restart any Claude Code, OpenCode, and Pi clients that were open during apply so their in-memory adapter configuration matches the deployed removal.
8. Start one child through `herdr-child` and one consult through `ask-in-herdr`; verify returned alias-plus-pane pairs support read, callback-alias refresh, reply, and reap.

The old `~/.cache/herdr-task-sync` directory is not migrated wholesale. The before-script copies only the validated location subset named in KTD9, and no managed source uses the old cache after cutover. A delayed old process can still write there temporarily; the new complete-snapshot sweep repairs visible labels after activation.

## Definition of Done

- While pool capacity remains, every complete live Herdr agent record converges to one unique alias from the repository-owned pool; exhaustion terminates under AE8 without partial presentation writes.
- At launch, registered names, pane labels, tabs, sidebar identity, child result JSON, and the child environment agree on the launch alias without rendering Git location. After callback refresh, reply and reap use the freshly verified callback alias for the launch pane; presentation converges on a later complete sweep.
- Existing valid aliases remain stable without a mapping database or semantic fallback.
- Concurrent allocation, target replacement, the documented non-atomic rename/close intervals, incomplete snapshots, alias reuse, and pool exhaustion have explicit safe defaults, accepted residuals, and focused tests.
- Process/idle labels, tab order, Git/worktree metadata, stale-location behavior, repair, and sweep idempotency retain regression coverage.
- The semantic adapters, model chain, prompt/transcript parsing, task state, task metadata publication, old executable, and deployed remnants are absent.
- Deployment starts `herdr-pane-labels --sweep-daemon` for sockets discovered by the existing cutover machinery; its complete-snapshot sweep eventually replaces temporary semantic or stale labels.
- Missing `herdr` during an active cutover exits non-zero and leaves activation pending for a later apply.
- Strict process-incarnation proofs, writer fencing, socket ledgers, and exact rollback preimages are not claimed or implemented.
- Retained location evidence remains covered by the existing regression tests.
- Live `task` tokens are cleared under source `task-sync`, while validated stale-location evidence survives the cache cutover.
- Callback documentation and executable behavior agree that the verified callback alias plus launch pane drive reply and reap.
- `bats tests/scripts.bats`, `make test-templates`, `make lint`, `make test-local`, `make test-ubuntu`, and `git diff --check` pass with no silently skipped applicable checks.

## Deferred / Open Questions

### From 2026-08-24 review

- **Pair checks do not identify the original occupant** — Product Contract: Launch and cleanup (P1, adversarial, confidence 75)

  A delayed reply or reap can target a replacement agent that occupies the same pane and terminal and has retained or reacquired the alias before validation begins. Herdr 0.8.2 exposes no always-present stable agent-instance identifier, so the plan cannot yet distinguish that replacement from the original occupant without inventing another registry.

- **Strict cutover takeover is intentionally deferred** — Planning Contract: convergence model

  The cutover does not prove that a delayed old writer can never publish after quiescence, nor does it journal every migration preimage. A later complete sweep is the recovery mechanism. Revisit strict takeover only if observed drift persists after successful activation.
