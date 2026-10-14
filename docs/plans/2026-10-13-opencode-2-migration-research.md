---
title: OpenCode 2 migration after the herdr-peer cutover
type: research
date: 2026-10-13
status: complete
execution: none
---

# OpenCode 2 migration after the herdr-peer cutover

## Verdict

Issue [#405](https://github.com/Seigiard/my-mac-setup/issues/405) is still needed. Removing Agent Intercom removed one migration dependency. Four local V1 plugins, child launch arguments, permission overrides, and headless commands still need changes. Herdr supports the V2 full TUI, but the inspected evidence does not prove automatic naming or peer delivery with a real V2 client.

Scope: checkout `15bb5af`, selected live configuration, repository issues and PRs updated October 9–13, and pinned upstream sources. This was a read-only investigation apart from this note. No V2 session was launched, package installed, configuration deployed, or GitHub issue changed. Runtime compatibility remains unverified.

The checkout pins **OpenCode 1.19.0**, not the historical 1.18.34 in #405. The latest V2 publication verified here is **2.0.28**, commit `026b106bc5d41b679ffc413264229c340871e4d3`. Its successful [publish run](https://github.com/anomalyco/opencode/actions/runs/38365643273) records the `latest` channel and `preview: false`. GitHub Releases reports a V1 latest release; that endpoint alone does not identify the current V2 package. [U1]

## Recent evidence and stale issue items

| Source | What it establishes | Limit |
|---|---|---|
| [#457](https://github.com/Seigiard/my-mac-setup/issues/457), [PR #458](https://github.com/Seigiard/my-mac-setup/pull/458) | Intercom and its argv-classifying launcher were removed. `herdr-peer` uses `herdr agent list` and `herdr agent prompt`. | The issue's generic argv-classifier item no longer names an existing Intercom component. |
| [PR #458 live result, October 12](https://github.com/Seigiard/my-mac-setup/pull/458#issuecomment-6127582492) | Nine client-kind directions delivered asks and replies among Claude, OpenCode, and Pi. | The two OpenCode clients were **1.18.35**, not V2. |
| [#463](https://github.com/Seigiard/my-mac-setup/issues/463), [PR #469](https://github.com/Seigiard/my-mac-setup/pull/469) | The `herdr agent list` fake is compared with Herdr's schema and live records. | The test does not launch V2, assign its alias, or deliver a message. An unnamed record is valid. |
| [PR #452](https://github.com/Seigiard/my-mac-setup/pull/452) | `pf-build` now delegates through the shared `tdd` chain. | Direct `pf-build` commands in #405 are stale. The incompatible `run --dir` remains in `tdd` and `pf-spec`. |
| [PR #449](https://github.com/Seigiard/my-mac-setup/pull/449) | Closing stdin fixed observed headless startup hangs on **1.18.35**. | It also records an uninvestigated blank TUI during `herdr-child` launch. That is a historical symptom, not a reproduced V2 defect. |
| [Herdr #5214, October 13](https://github.com/herdrdev/herdr/issues/5214#issuecomment-6136735677) | Herdr's empty V2 server setup is intentional. Session reporting belongs to the pane-local TUI. | V2 Mini/headless reporting is explicitly unsupported. A loaded server plugin is not proof of session reporting. |

## Current blockers

### 1. Four repository-owned plugins still use V1

All four files under `home/private_dot_config/opencode/plugins/` export named V1 factories. V2 requires a default definition with `id` and `setup` or `effect`. [U2]

| Local plugin | Current boundary | Required migration |
|---|---|---|
| `agent-hooks.ts` | `tool.execute.before`, `input.tool`, `output.args` | `ctx.tool.hook("execute.before")`, `event.tool`, `event.input`; adapt tool names and payloads too. |
| `agents-local.ts` | `experimental.chat.system.transform`, factory `directory` | Session `context` hook; resolve the correct session directory, rather than assuming the plugin load location owns every session. |
| `herdr-resource-context.ts` | System transform and server process environment | Session `context` hook with real session ID and correct pane attribution. |
| `herdr-worktree-identity.ts` | `chat.message`, `event.properties.info` | Session `prompt` hook and V2 event stream; retain child-session exclusion and root prompt handoff. |

Loading is only the first acceptance check. The local guard registry maps `bash`, not V2 `shell`. Its OpenCode normalizer reads `filePath` or `file_path`, not the V2 `path` used by `edit` and `write`. Unknown tools normalize to `undefined`; policy dispatch therefore needs more than a hook rename. [L1, U3]

V2 MCP names are `sanitize(server) + "_" + sanitize(tool)`. `fff_grep` remains correct only if the remote tool is actually named `grep`. Code Mode wraps MCP calls in `execute`, but nested registered tool calls still pass through the tool hook. Confirm the installed FFF schema at that boundary. [U4]

### 2. Server environment and pane ownership

V2 normally connects to a shared server. A local server plugin's `process.env` is not the environment of each connecting pane. `--standalone` starts a private server with the caller's environment and is the simplest initial migration path for the existing local adapters. It does not isolate HOME, configuration, or the database. [U5]

The issue's statement that all client environment is lost is too broad for 2.0.28. The shared-service run path passes client environment to its session, and shell execution can use that environment. This does not update the server plugin's `process.env`. Herdr's own V2 reporting avoids this problem by running in the TUI. Keep these three boundaries separate: server plugin, session shell, and TUI plugin. [U5, H2]

### 3. Child launch and permissions

`home/dot_local/lib/herdr-child-launch.sh:186–194,382–387` still sets `OPENCODE_PERMISSION` and passes `--model` plus optional `--agent` to the full TUI. Neither flag exists on the V2 root command. They remain on `run` and `mini`. The inspected V2 server configuration does not read `OPENCODE_PERMISSION`; it does read `OPENCODE_CONFIG_CONTENT`. [U6]

An initial migration candidate is a per-launch configuration overlay plus `--standalone`. It must preserve existing configuration and select the requested agent/model for a fresh session. Configuration defaults are not unconditional CLI overrides: resumed sessions and agent-specific models need explicit verification. The current managed `build` agent already has a model and variant in `opencode.json.tmpl`. [L2, U6]

The local `ro` posture denies edit and question tools while retaining shell callbacks. It is not filesystem confinement. Preserve that actual contract when converting permissions. Replacing the full TUI with `mini` would lose Herdr's supported V2 session/lifecycle reporting and is not an equivalent solution. [H3]

### 4. Headless workflows

`home/private_dot_agents/skills/tdd/SKILL.md:160` and `pf-spec/SKILL.md:56` still call `opencode run --dir`. V2 `run` has no such flag. Launch it in the intended working directory and keep `PWD` consistent with the process cwd: V2 reads `process.env.PWD` first. Preserve stdin closure from PR #449. [U6]

`pf-build`, `implement`, `implement-spec`, and code-review fixes now inherit the shared chain's launch behavior. The issue should name `tdd` and `pf-spec` as the direct command owners. Headless success also needs verification of JSONL session identity and resume behavior, not only process exit.

## Herdr naming: what exists and what is missing

There are three distinct boundaries:

1. **Detection:** Herdr recognizes the foreground process as OpenCode.
2. **Alias:** `herdr-pane-labels` assigns a unique `color-animal` name through `herdr agent rename`.
3. **Session identity:** the Herdr OpenCode TUI plugin reports the native session ID and lifecycle for that pane.

Herdr 0.9.3 recognizes `opencode`, `opencode2`, and `open-code`. Its unit tests include a synthetic foreground job with `opencode2 --standalone`. Its V2 TUI adapter also has tests for lifecycle, blockers, session changes, and delivery retries. These tests use synthetic process data or a fake V2 API and mocked socket; they are not a live V2 naming result. [H1, H2]

The pinned alias package is `Seigiard/herdr-pane-labels` at `aba61eb788c5fe0630dc570d96fd14683e2f63c7`, version 0.2.3. The live plugin registry matched that pin during inspection. The package reads Herdr snapshots, chooses a free alias, renames the agent, then verifies the new snapshot. It permits a missing/null session ID. Its OpenCode fixture verifies a mocked record and the `oc:` prefix. Therefore a missing session report does not, by itself, prove that alias assignment must fail. [H4]

`herdr-child` selects an alias first and passes it explicitly to `herdr agent start`. A successful child name does not prove automatic naming after a plain manual `opencode` launch. `herdr-peer-alias` only prints a candidate; it does not register an agent. [L3]

**Concrete host configuration gap:** the inspected `~/.config/opencode/cli.json` had no `plugins` entry, although `~/.config/opencode/herdr-opencode/tui.js` existed. Herdr's V2 installer expects `"plugins": ["./herdr-opencode"]`. A project configuration or CLI environment overlay could provide another registration; the effective running V2 configuration was not measured. This is a default-config gap, not a reproduced alias failure. [H5]

The repository already delegates generated integration files to `herdr integration install opencode` in `home/.chezmoiscripts/run_onchange_after_3-setup-herdr-integrations.sh.tmpl`. Migration should establish the installer/configuration ordering and verify the loaded TUI integration. It should not introduce a second owner for Herdr's generated files.

`herdr-peer` requires exactly one non-empty name for its own `HERDR_PANE_ID`. Thus alias allocation is a real dependency of the new communication path, even though Intercom is gone. [L4]

## Proposed migration order and runtime evidence

1. Port the four local plugins, including tool payload normalization and event handling. Use a pinned V2 binary in an isolated migration environment before changing the normal launch path.
2. Adapt full-TUI child launch, permission overlays, and the two direct headless command owners. Establish Herdr's TUI registration after V2 configuration migration.
3. Run the following live checks with the real V2 binary and real Herdr. Record binary versions, launch command, pane/terminal/session IDs, and exact outcomes.
4. Change the mise pin only after those checks pass. Verify the package/backend selection: V2's publication channel differs from the V1 GitHub Releases channel. Apply the repository's deployment verification gates for the resulting managed changes.

| Live scenario | Observable pass criterion |
|---|---|
| Two plain full-TUI launches in separate panes | Each gets a distinct non-empty alias without an explicit name; each reports its own native session and pane. |
| Close and relaunch in a used pane | The active process remains addressable; no stale alias/session routes a message to the previous process. |
| `herdr-child` full-TUI launch | Requested model/agent are effective; edit/question restrictions hold; shell return channel works; parent sees the correct child session and completion. |
| Peer ask/reply while idle and while busy | The addressed V2 agent receives a nonce and replies to the sender; a different pane does not receive it. Repeat V2→V2 and V2↔another supported client. |
| Local plugin behavior | Guard denial and a nearby allowed control work; local instructions come from the correct worktree; resource context belongs to the right pane/session; worktree identity excludes child sessions. |
| Headless chain and spec launch | Correct cwd, selected model, JSONL session ID, resume, terminal verdict, and closed stdin; do not require unsupported Herdr headless reporting. |

These are proposed migration evidence, not completed tests. No permanent test was added for this research note. Existing V1 tests and Herdr schema calibration cannot serve as the oracle for a live V2 transition.

## Suggested changes to #405

- Keep the issue open; Intercom removal does not complete it.
- Replace the old argv-classifier work with concrete remaining launch paths.
- Replace direct `pf-build --dir` ownership with `tdd` and `pf-spec`.
- Add V2 tool names/payloads, permission configuration, and Herdr TUI registration.
- Add separate acceptance checks for automatic alias allocation, explicit child aliases, and native session/lifecycle reporting.
- Require V2 peer delivery evidence. Link the V1-only result from #458 and the narrower schema check from #469 to prevent reuse as V2 proof.

## Source index

Local references are relative to checkout `15bb5af`:

- **L1:** `home/dot_local/lib/agent-hooks/registry.ts:35–38`; `normalize.ts:67–79,129–133`; the four files under `home/private_dot_config/opencode/plugins/`.
- **L2:** `home/dot_local/lib/herdr-child-launch.sh:186–194,382–387`; `home/private_dot_config/opencode/opencode.json.tmpl:14–19`; `home/private_dot_config/mise/config.toml:10–12`.
- **L3:** `home/dot_local/lib/herdr-child-launch.sh:96–142,411`; `home/dot_local/bin/executable_herdr-peer-alias`.
- **L4:** `home/dot_local/bin/executable_herdr-peer:8–17,50–64`.

OpenCode sources are pinned to V2 2.0.28:

- **U1:** [publish run](https://github.com/anomalyco/opencode/actions/runs/38365643273), [source commit](https://github.com/anomalyco/opencode/commit/026b106bc5d41b679ffc413264229c340871e4d3).
- **U2:** [migration guide](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/services/www/src/docs/content/build/plugins/migrate-v1.mdx), [loader](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/core/src/plugin/module.ts#L78-L134).
- **U3:** [edit](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/core/src/tool/plugin/edit.ts#L22-L34), [write](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/core/src/tool/plugin/write.ts#L20-L28), [shell](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/core/src/tool/plugin/shell.ts#L23-L53).
- **U4:** [MCP naming and input](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/core/src/tool/mcp.ts#L13-L69), [nested tool hook](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/core/src/tool.ts#L234-L243).
- **U5:** [server selection](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/services/server-connection.ts#L21-L50), [standalone](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/services/standalone.ts#L15-L32), [run session environment](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/run/run.ts#L91-L103), [shell environment](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/core/src/shell.ts#L258-L274).
- **U6:** [CLI commands and flags](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/commands/commands.ts), [server config environment](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/server-process.ts#L115-L122), [permission schema](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/schema/src/permission.ts#L56-L67), [defaults](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/schema/src/config.ts#L32-L37), [run cwd](https://github.com/anomalyco/opencode/blob/026b106bc5d41b679ffc413264229c340871e4d3/packages/cli/src/run/run.ts#L71-L76).

Herdr sources are pinned to 0.9.3 (`7b116c05bfda646af39d2524c54e70c751f57ee8`):

- **H1:** [process identification](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/detect/mod.rs#L209-L212), [synthetic V2 job test](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/detect/mod.rs#L1649-L1664).
- **H2:** [V2 TUI adapter](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/integration/assets/opencode/herdr-tui-session.js#L406-L604), [fake API](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/integration/assets/opencode/herdr-tui-session.test.ts#L241-L277), [V2 cases](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/integration/assets/opencode/herdr-tui-session.test.ts#L552-L703).
- **H3:** [server export](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/integration/assets/opencode/herdr-agent-state.js#L218-L224), [upstream support boundary](https://github.com/herdrdev/herdr/issues/5214#issuecomment-6136735677).
- **H4:** [alias snapshot validation](https://github.com/Seigiard/herdr-pane-labels/blob/aba61eb788c5fe0630dc570d96fd14683e2f63c7/bin/herdr-pane-labels#L977-L1069), [assignment](https://github.com/Seigiard/herdr-pane-labels/blob/aba61eb788c5fe0630dc570d96fd14683e2f63c7/bin/herdr-pane-labels#L1104-L1145), [OpenCode fixture](https://github.com/Seigiard/herdr-pane-labels/blob/aba61eb788c5fe0630dc570d96fd14683e2f63c7/tests/bashunit/pane_labels_behavior_test.sh#L246-L275).
- **H5:** [migration-aware TUI registration](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/integration/opencode_config.rs#L54-L74), [validity check](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/integration/registry.rs#L416-L440). Host observation: `~/.config/opencode/cli.json` on 2026-10-13 had theme/diffs/session/animations settings but no `plugins` key.
