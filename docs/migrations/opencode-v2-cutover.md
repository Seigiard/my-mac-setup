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

The prerequisite issues are closed and their documented `2.0.28` live evidence
is the historical release gate for this cutover. A combined `2.0.25` rerun is
still pending before this formula can be treated as an equivalent live boundary.
Lifecycle idle is a state observation, not task success.

| Boundary | Result | Evidence |
| --- | --- | --- |
| Full-TUI identity, lifecycle, peer routing, busy delivery, and reused panes | Passed with OpenCode `2.0.28` and Herdr `0.9.3`; distinct automatic peer addresses and queued messages were observed. | #471, [full-TUI probe](../opencode-v2-full-tui-probe.md) |
| Hooks guards | Passed for V2 shell, write, edit, and nested FFF calls; explicit denials remained distinct from fail-open adapter failures. | #472, [agent-hooks boundary](opencode-v2-agent-hooks.md) |
| Per-session instructions and resource context | Completed for separate V2 conversations, including refresh and resume isolation. | #473, PR #484 |
| Generated-worktree naming | Completed for authorized V2 root prompts; child prompts and unauthorized worktrees remain excluded. | #474, PR #497 |
| Full-TUI child lifecycle | Completed for requested model, agent, posture, callback, follow-up, attribution, and safe reaping. | #475, PR #501 |
| Headless chain and spec workflow | Completed with cwd, model, JSONL identity, resume, closed stdin, and terminal-result distinctions observed on V2. | #476, PR #479 |

The reusable probes establish the OpenCode `2.0.28` boundary, not a guarantee
for the current `2.0.25` formula or every future Homebrew formula update. Run
the affected live probes from their required parent panes, record the exact
`opencode --version` and `herdr --version`, and complete the remaining combined
live slices before relying on this formula release. This repository does not
own OpenCode or Herdr runtime semantics, so no local source-shape test
substitutes for that live check.

## Deployment Order

The operator runs deployment. Do not run `chezmoi apply` on the host from this
checkout.

1. Update the chezmoi source clone with the committed cutover, then run the
   normal user-owned `chezmoi apply`.
2. Run `brew bundle --file ~/.config/brewfiles/Brewfile`, then `brew upgrade
   opencode` when the formula was already installed. Confirm the package comes
   from the current Homebrew formula.
3. Remove the old mise-managed installation with `mise uninstall opencode`.
   Confirm `command -v opencode` resolves to Homebrew's prefix, not a mise shim,
   then record `opencode --version`.
4. Run `herdr integration install opencode` after the Homebrew binary is active.
   Herdr owns the generated `plugins/herdr-agent-state.js` and
   `herdr-tui-session.js` files and its `tui.jsonc` registration. Do not copy
   those generated files into this repository.
5. Restart OpenCode and Herdr clients from the managed zsh environment. Run the
   focused live probe appropriate to the installed version before treating the
   rollout as complete.

Removing the stale mise installation is required. A mise shim can appear first
on `PATH` and silently run the old binary after Homebrew installs V2.

## Rollback

Binary rollback and client-data migration are separate operations.

To return to the previous binary, install the desired prior formula version
using the maintainer's supported Homebrew procedure, or reinstall the prior
mise tool only as an explicit temporary owner change. Do not leave both
Homebrew and mise installations on `PATH`; verify the selected binary with
`command -v opencode` and `opencode --version`. Restore Homebrew as the sole
owner after the temporary rollback is no longer needed.

Changing the binary does not migrate or erase persistent OpenCode data. Before
rollback, back up `~/.local/share/opencode` and `~/.config/opencode`, including
sessions, authentication state, and user configuration. Do not assume V1 can
read data written by V2. If V1 fails after binary rollback, restore the backed
up V1-era client data and rerun Herdr's integration installer for the selected
client version. Generated Herdr files remain installer-owned in both directions.

## Acceptance Status

#405 has the `2.0.28` prerequisite evidence and this change makes Homebrew the
only normal installer. The `2.0.25` combined live rerun and its remaining
headless, hook, instruction/resource-context, and worktree-naming slices are
still required completion gates. A successful process exit or an idle lifecycle
state alone is not acceptance evidence.
