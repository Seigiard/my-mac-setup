# OpenCode 2 Cutover

## Decision

Homebrew is the sole package owner for OpenCode. The managed full Brewfile
declares `brew "opencode"`; `mise/config.toml` no longer declares OpenCode.
The formula tracks Homebrew's current stable release, rather than a repository
pin.

On 2026-10-14, `brew info --json=v2 opencode` resolved the `homebrew/core`
formula to stable `2.0.25`. The existing live migration probes used
`@opencode/cli` `2.0.28` and Herdr `0.9.3`. The formula version is installation
evidence only, not a promise that a later Homebrew update has the same result.

## Evidence Summary

The prerequisite issues are closed. Their documented `2.0.28` live evidence is
the historical release gate for this cutover. The maintainer accepted that
per-slice evidence for criteria 2, 4, 5, and 6 on 2026-10-14; those criteria
were not rerun as combined `2.0.25` scenarios. Lifecycle idle is a state
observation, not task success.

| Boundary | Result | Evidence |
| --- | --- | --- |
| Criterion 2: combined tools, pane context, and worktree naming | Per-slice V2 evidence passed on OpenCode `2.0.28`; no combined `2.0.25` rerun. | #472, #473, #474; [agent-hooks boundary](opencode-v2-agent-hooks.md), PR #484, PR #497 |
| Criterion 3: full-TUI child lifecycle | Passed in a 2026-10-14 parent-pane run on OpenCode `2.0.25` with all four managed plugins active together. Model, agent, posture, callback, follow-up, attribution, and safe reaping were verified. | The run returned `result=passed` and `terminal-result=passed`; provider verification confirmed the effective model, posture, and tool permissions. |
| Criterion 4: headless chain and spec workflow | Per-slice V2 evidence passed on OpenCode `2.0.28`; no combined `2.0.25` rerun. Cwd, model, JSONL identity, resume, closed stdin, and terminal-result distinctions were observed. | #476, PR #479 |
| Criterion 5: peer addresses and messages | Per-slice V2 evidence passed on OpenCode `2.0.28`; no combined `2.0.25` rerun. Distinct automatic peer addresses, queued delivery, and reused-pane behavior were observed. | #471, [full-TUI probe](../opencode-v2-full-tui-probe.md) |
| Criterion 6: Herdr TUI registration and install order | Per-slice V2 evidence passed on OpenCode `2.0.28`; no combined `2.0.25` rerun. Generated files remained installer-owned. | #475, PR #501 |

The reusable per-slice probes establish the OpenCode `2.0.28` boundary, and the
2026-10-14 combined parent-pane run establishes the full-TUI child-lifecycle
boundary for the current `2.0.25` formula. The maintainer accepted the per-slice evidence for
criteria 2, 4, 5, and 6; it is not equivalent to combined `2.0.25` evidence.
These results are not a guarantee for every future Homebrew formula update.
For a later formula update, run the affected live probes from their required
parent panes and record the exact `opencode --version` and `herdr --version`.
This repository does not own OpenCode or Herdr runtime semantics, so no local
source-shape test substitutes for that live check.

The V1 rollback fallback is no longer exercised by any automated test after this
cutover. Test 1227 (`test_scripts_1227_opencode_v1_worktree_identity_loader_registers_the_named_prompt_handler`),
which verified the V1 loader and Herdr integration, is deleted under #512 because
the managed setup no longer installs an OpenCode `1.19.0` binary. The V1 rollback
path is now a coverage limit: rollback must be verified manually if needed.

## Deployment Order

The operator runs deployment. Do not run `chezmoi apply` on the host from this
checkout.

1. While V1 is still active, before applying the cutover or starting V2, create
   and record an immutable V1-era snapshot of both client data paths. Use a
   separate directory for this snapshot, and record a missing path as absent:

   ```sh
   v1_backup="$HOME/opencode-v1-cutover-$(date +%Y%m%d-%H%M%S)"
   mkdir -p "$v1_backup"
   [ ! -e "$HOME/.local/share/opencode" ] || cp -a \
     "$HOME/.local/share/opencode" "$v1_backup/local-share-opencode"
   [ ! -e "$HOME/.config/opencode" ] || cp -a \
     "$HOME/.config/opencode" "$v1_backup/config-opencode"
   ```

   Keep the recorded `v1_backup` unchanged after V2 starts. It is the source
   for client-data rollback, not the backup of any later V2 state.
2. Update the chezmoi source clone with the committed cutover, then run the
   normal user-owned `chezmoi apply`.
3. Run `brew bundle --file ~/.config/brewfiles/Brewfile`, then `brew upgrade
   opencode` when the formula was already installed. Confirm the package comes
   from the current Homebrew formula.
4. Remove every old mise-managed installation. First check that mise holds no
   install shipping an `opencode` binary. If any row appears in `mise ls | grep
   -i opencode`, uninstall every such backend (for example `mise uninstall
   npm:@opencode/cli`) before running `mise uninstall --all opencode`. Then run
   `mise reshim` if the stale shim still exists, and require that
   `~/.local/share/mise/shims/opencode` is absent. Check resolution with the
   non-interactive PATH used by `herdr-run`, which puts that shims directory
   first, and record the version from the same check:

   ```sh
   ! mise ls | grep -i opencode
   test ! -e "$HOME/.local/share/mise/shims/opencode"
   brew_opencode="$(brew --prefix)/bin/opencode"
   PATH="$HOME/.local/share/mise/shims:$PATH" /bin/sh -c \
     'test "$(command -v opencode)" = "$1" && command -v opencode && opencode --version' \
     sh "$brew_opencode"
   ```

5. Run `herdr integration install opencode` after the Homebrew binary is active.
   Herdr owns the generated `plugins/herdr-agent-state.js` and
   `herdr-tui-session.js` files and its `tui.jsonc` registration. Do not copy
   those generated files into this repository.
6. Restart OpenCode and Herdr clients from the managed zsh environment. Run the
   focused live probe appropriate to the installed version before treating the
   rollout as complete.

Removing the stale mise installation is required. A mise shim can appear first
on `PATH` and silently run the old binary after Homebrew installs V2.

## Rollback

After this cutover under #512, the managed plugins, herdr-child scripts, and
agent-hooks normalizer support only OpenCode 2. A complete rollback to OpenCode 1.x
requires restoring the chezmoi source to before #512 (commit d274a58 or earlier),
not just the binary and client data. Binary rollback and client-data migration are
separate operations. The `<v1-backup>` path below is the `v1_backup` directory
recorded before deployment; it must remain distinct from the V2 backup created
during rollback.

To return to the previous binary, install the desired prior formula version
using the maintainer's supported Homebrew procedure, or reinstall the prior
mise tool only as an explicit temporary owner change. Do not leave both
Homebrew and mise installations on `PATH`; verify the selected binary with
`command -v opencode` and `opencode --version`. Restore Homebrew as the sole
owner after the temporary rollback is no longer needed. You must also check out
and apply the chezmoi source from before #512 (commit d274a58 or earlier) to use
OpenCode 1.x, as the current managed plugins and scripts do not support V1.

Changing the binary does not migrate or erase persistent OpenCode data. Before
rollback, stop OpenCode and back up the current V2 state to a new, separate
directory, including sessions, authentication state, and user configuration:

```sh
v2_backup="$HOME/opencode-v2-before-rollback-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$v2_backup"
[ ! -e "$HOME/.local/share/opencode" ] || cp -a \
  "$HOME/.local/share/opencode" "$v2_backup/local-share-opencode"
[ ! -e "$HOME/.config/opencode" ] || cp -a \
  "$HOME/.config/opencode" "$v2_backup/config-opencode"
```

Do not assume V1 can read data written by V2. After selecting the V1 binary,
restore the V1 snapshot, replacing the current V2 paths:

```sh
rm -rf "$HOME/.local/share/opencode" "$HOME/.config/opencode"
mkdir -p "$HOME/.local/share" "$HOME/.config"
[ ! -e "<v1-backup>/local-share-opencode" ] || cp -a \
  "<v1-backup>/local-share-opencode" "$HOME/.local/share/opencode"
[ ! -e "<v1-backup>/config-opencode" ] || cp -a \
  "<v1-backup>/config-opencode" "$HOME/.config/opencode"
```

If V1 fails after the binary rollback, keep the V2 backup for investigation,
verify the restored V1 snapshot, and rerun Herdr's integration installer for
the selected client version. Generated Herdr files remain installer-owned in
both directions.

## Acceptance Status

#405 has the `2.0.28` prerequisite evidence and this change makes Homebrew the
only normal installer. Criterion 3 is accepted as passed on OpenCode `2.0.25`
with all four managed plugins active together in the 2026-10-14 parent run; it
returned `result=passed` and `terminal-result=passed` while verifying model,
agent, posture, callback, follow-up, attribution, and safe reaping. Criteria 2, 4,
5, and 6 remain represented by their per-slice OpenCode `2.0.28` evidence only,
which the maintainer accepted on 2026-10-14; no combined `2.0.25` rerun was claimed
for those criteria. A successful process exit or an idle lifecycle state alone
is not acceptance evidence.
