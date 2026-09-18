---
title: Herdr Command Palette Alternatives - Research
type: research
date: 2026-09-16
topic: herdr-command-palette-alternatives
status: complete
execution: none
issue: https://github.com/Seigiard/my-mac-setup/issues/258
---

# Herdr Command Palette Alternatives - Research

## What this document is

This note asks whether issue
[#258](https://github.com/Seigiard/my-mac-setup/issues/258) should adopt and
configure an existing Herdr plugin instead of extracting this repository's
current command palette into its own package.

The evidence was collected on 2026-09-16. Product and compatibility facts come
from first-party documentation, repository source, manifests, release records,
and license files. The candidate score and recommendation are judgments based on
those facts. Marketplace and awesome-list descriptions were used for discovery,
not as proof of behavior.

## Recommendation

**Extract the current implementation. Do not adopt any evaluated plugin as the
behavior-preserving implementation of #258.**

[`cloudmanic/herdr-plus`](https://github.com/cloudmanic/herdr-plus) is the only
candidate close enough to justify serious consideration. It has excellent
packaging, releases, documentation, dynamic selects, forms, invocation context,
and project/global action discovery. It nevertheless misses four parts of the
required contract at its core:

- no shortcut/alias tier ahead of title search;
- one file per action rather than one user-owned command file;
- project actions require a repo-local `.herdr-plus/quick-actions/` tree;
- no equivalent of `seigi.command-palette.smart_close`.

It also runs a selected shell command before the palette process exits and
interpolates an explicit `{{.Value}}` directly into `sh -c`. The current palette
deliberately rejects a bare shell `{value}` at load time. Adopting herdr-plus
would therefore require changes to its config model, matcher, project discovery,
dispatch lifecycle, and value-safety contract, plus a separate smart-close
solution. That is a fork or upstream feature project, not configuration.

[`vjeantet/herdr-palette`](https://github.com/vjeantet/herdr-palette) is the best
general command palette and the best one-file configuration model evaluated. It
does not provide project-scoped user commands, aliases, user-defined selects, or
the current shell/pane/tab execution modes. The remaining candidates miss still
more of the contract.

Extraction should preserve the existing plugin and action IDs
(`seigi.command-palette.open` and `seigi.command-palette.smart_close`) and keep
the user-owned command file outside the package checkout. This avoids a caller
migration altogether. Borrow the candidates' packaging practices: native
`herdr plugin install`, a declared `min_herdr_version` and platform matrix,
checksummed release binaries with a documented source-build fallback, and
`herdr plugin uninstall` with config preserved.

## Decision boundary

This recommendation is specific to #258's instruction not to combine extraction
with a rewrite or new features. It would change if the maintainer accepts all of
the following behavior changes:

- remove deterministic per-command shortcuts;
- replace the current command types with shell-only quick actions;
- accept file-per-action configuration and repo-local `.herdr-plus` directories;
- keep smart close as a separate local helper;
- accept herdr-plus's command-before-popup-exit and explicit-value interpolation
  behavior.

Without that product decision, adopting herdr-plus is not a smaller extraction;
it is a migration to a different command-palette contract.

## Required behavior baseline

The issue names command dispatch, project/global configuration,
shortcut-before-title search, pickers/forms, contextual execution, smart close,
stable IDs or an explicit migration, declared dependencies and compatibility,
tested install/update/removal, and licensing. The local implementation makes
those terms concrete:

| Requirement | Current verified behavior |
|---|---|
| Command dispatch | Nine declared types: `herdr`, `pane_run`, `tab_run`, `shell`, `overlay_shell`, `plugin_action`, `workspace_picker`, `select`, and `form` (`home/private_dot_config/herdr/plugins/command-palette/README.md:85-97`). |
| One-file configuration | All current personal commands are in one chezmoi-managed `commands.toml`; sibling files are optional (`README.md:42-60`). |
| Global/project commands | Global files are loaded from the user config directory. Project files are found by walking upward for `.herdr/command-palette/`, loaded read-only, and grouped ahead of global commands (`palette.py:223-246`, `:450-457`). |
| Shortcut-before-title search | Case-insensitive exact/prefix shortcut hits are ranked first; remaining titles are scored by `fzf`. Group and description are not searched (`palette.py:620-673`). |
| Pickers/forms | Static or command-generated selects and text forms run a nested command with a safely expanded value (`README.md:148-192`; `palette.py:1842-1858`). |
| Contextual execution | The opener captures the originating pane and cwd. Commands receive target pane/cwd, project root, config/plugin/state paths, and the selected value (`open.py:172-229`; `README.md:194-217`). |
| Smart close | Close the focused pane when its tab has multiple panes; otherwise close the tab when its workspace has multiple tabs; otherwise retain the last tab and notify (`smart_close.py:54-79`). |
| Stable IDs | `seigi.command-palette.open`, `seigi.command-palette.smart_close`, and the `palette` and `lazygit` pane IDs are declared in the manifest (`herdr-plugin.toml:1-32`). |
| Dependencies/platforms | Python 3 and `fzf`; Herdr >= 0.7.0; macOS and Linux (`herdr-plugin.toml:4-6`; `README.md:118-121`). |

Two qualifications matter:

- The existing project-local feature itself uses repository configuration. No
  project-local palette files exist in this checkout. If “without repository-
  local clutter” means project-specific commands must live in a central user
  file, neither the current implementation nor any candidate meets that stronger
  shape. It should be a separately specified config-model change, not silently
  folded into extraction.
- The current `tab_run` and lazygit-popup paths still contain sleep-based focus
  workarounds tracked separately by
  [#234](https://github.com/Seigiard/my-mac-setup/issues/234). They are current
  observable behavior, not evidence that the timing mechanism should be copied.

## Discovery and screening

Herdr's official marketplace is an automated index of public repositories with
the `herdr-plugin` topic and a parseable manifest. Herdr explicitly says listings
are not reviewed. The marketplace contained 1,180 entries when checked; the
official guidance is to inspect each manifest and implementation before install
([marketplace](https://herdr.dev/plugins/),
[trust and publishing rules](https://herdr.dev/docs/plugins/#trust-and-security)).

The “Command palettes and workspace switchers” section of
[`awesome-herdr`](https://github.com/yigitkonur/awesome-herdr#command-palettes-and-workspace-switchers)
contained 26 entries. A candidate received a full evaluation if it could dispatch
arbitrary user commands or presented a broad command surface that plausibly could
replace the current palette.

The following adjacent tools were screened out before the full matrix because
their own repositories describe a materially narrower product:

| Candidate | Verified scope | Why it is not realistic for #258 |
|---|---|---|
| [`JanTvrdik/herdr-command-palette`](https://github.com/JanTvrdik/herdr-command-palette) | Fuzzy-picks actions exposed by installed plugins. | No personal command schema, forms, project/global commands, or smart close. |
| [`hota911/herdr-command-palette`](https://github.com/hota911/herdr-command-palette) | Catalog of Herdr built-in operations. | No personal command schema or contextual project commands. |
| [`haisi/herdr-plugin-command-palette`](https://github.com/haisi/herdr-plugin-command-palette) and [`fabiogaliano/herdr-command-palette`](https://github.com/fabiogaliano/herdr-command-palette) | Search effective Herdr keybindings/actions. | Useful keybinding browsers, not replacements for the current configurable dispatcher. |
| [`Binb1/herdr-palette`](https://github.com/Binb1/herdr-palette) | Workspaces/agents, plugin actions, and a small built-in command catalog ([README](https://github.com/Binb1/herdr-palette/blob/main/README.md)). | No arbitrary user commands, forms, project/global config, or smart close. |
| [`alon-z/herdr-command-palette`](https://github.com/alon-z/herdr-command-palette) and [`crafts69guy/herdr-switchboard`](https://github.com/crafts69guy/herdr-switchboard) | Workspace, agent, and repository navigation. | Navigation tools rather than general command dispatchers. |

## Behavior comparison

Legend: **Yes** means directly verified; **Partial** means a workaround or only a
subset; **No** means the capability is absent from the documented schema/source.

| Candidate | Dispatch | One user file | Project + global without repo config | Shortcut before title | Selects/forms | Origin context | Smart close |
|---|---|---:|---:|---:|---:|---:|---:|
| herdr-plus Quick Actions | Partial | No | No | No | Yes | Yes | No |
| vjeantet palette | Partial | Yes | No | No | Partial | Yes | No |
| arjenblokzijl launcher | Partial | No | No | No | Yes | Yes | No |
| speardragon Command Center | Partial | Yes | No | Partial | No | Yes | No |
| vika2603 palette | Partial | Partial | No | No | Partial | Yes | No |
| ramarivera palette | No for user commands | Partial | No | No | No | Yes | No |

No candidate meets the shortcut tier or smart-close requirement. No candidate
supports centrally configured project-specific visibility without repo-local
configuration. Those are not packaging gaps; they determine what appears, what
wins a search, and what a bound key does.

### 1. cloudmanic/herdr-plus Quick Actions

**Verified strengths**

- Native plugin install, Herdr >= 0.7.0, and declared Linux/macOS/Windows support
  ([manifest](https://github.com/cloudmanic/herdr-plus/blob/f38df3570bea8f7ca71dc1ba11bce3b123d14402/herdr-plugin.toml)).
- `command`, `select`, and `form` actions; selects support static options or an
  `options_command` evaluated when opened
  ([action schema and execution](https://github.com/cloudmanic/herdr-plus/blob/f38df3570bea8f7ca71dc1ba11bce3b123d14402/action.go#L91-L107),
  [dynamic options](https://github.com/cloudmanic/herdr-plus/blob/f38df3570bea8f7ca71dc1ba11bce3b123d14402/action.go#L193-L236)).
- Captures the originating pane/workspace/agent IDs and working directory, exposes
  them as templates and `HERDR_PLUS_*` variables, and runs the command in the
  originating cwd
  ([context reference](https://herdrplus.com/docs/variables/),
  [execution](https://github.com/cloudmanic/herdr-plus/blob/f38df3570bea8f7ca71dc1ba11bce3b123d14402/action.go#L239-L257)).
- Separates project and global actions. Project actions are read-only and never
  generated
  ([Quick Actions docs](https://herdrplus.com/docs/quick-actions/)).
- Active release line with checksummed binaries: latest verified release
  [v0.1.24 on 2026-08-28](https://github.com/cloudmanic/herdr-plus/releases/tag/v0.1.24),
  followed by source activity on 2026-09-04. MIT license
  ([license](https://github.com/cloudmanic/herdr-plus/blob/main/LICENSE)).
- Reinstall is the documented update operation; uninstall preserves plugin config
  ([installation](https://herdrplus.com/docs/installation/)). Unix install prefers
  Go and falls back to a release binary; Windows install requires Go.

**Verified conflicts and gaps**

- Configuration is one TOML file per action. Global files live under
  `quick-actions/`; project files must live under
  `<cwd>/.herdr-plus/quick-actions/`
  ([loader](https://github.com/cloudmanic/herdr-plus/blob/f38df3570bea8f7ca71dc1ba11bce3b123d14402/config.go#L140-L163),
  [merge](https://github.com/cloudmanic/herdr-plus/blob/f38df3570bea8f7ca71dc1ba11bce3b123d14402/config.go#L276-L292)).
  The source joins the launch cwd directly rather than walking to a repository
  root, so launching from a subdirectory is a compatibility gap unless Herdr's
  supplied cwd is already the root.
- First launch creates the global directory and seeds examples if the directory
  does not exist. It does not overwrite an existing directory, so chezmoi can
  avoid a collision by deploying it first, but package and dotfiles ownership
  still need an explicit rule
  ([seeding source](https://github.com/cloudmanic/herdr-plus/blob/f38df3570bea8f7ca71dc1ba11bce3b123d14402/config.go#L166-L212)).
- The action schema has no shortcut/alias field. Search fuzzy-matches `name +
  description`, exactly the surface the current palette rejected because group
  or descriptive words can displace the intended title
  ([matcher](https://github.com/cloudmanic/herdr-plus/blob/f38df3570bea8f7ca71dc1ba11bce3b123d14402/fuzzylist.go#L129-L170)).
- The only user dispatch primitive is a shell string. Calling Herdr or another
  plugin is possible from that string, but the current typed `pane_run`,
  `tab_run`, `overlay_shell`, `plugin_action`, and workspace-picker semantics
  must be reimplemented in user commands.
- The chosen command runs synchronously before the picker process exits and the
  plugin pane is torn down
  ([UI lifecycle](https://github.com/cloudmanic/herdr-plus/blob/f38df3570bea8f7ca71dc1ba11bce3b123d14402/quickactionspicker.go#L407-L445)).
  A command that needs to open another popup therefore needs handoff/delay logic;
  this does not replace the current smart-close or focus semantics.
- An explicit `{{.Value}}` is rendered verbatim into a command passed to the
  shell. Only the implicit “append the value” path shell-quotes it
  ([rendering](https://github.com/cloudmanic/herdr-plus/blob/f38df3570bea8f7ca71dc1ba11bce3b123d14402/action.go#L175-L190)).
  Migrating current forms/selects would lose their load-time rejection of a bare
  shell value unless every command is manually audited and rewritten.
- The plugin also installs Projects and worktree event handlers. They are inert
  without matching config, but are extra package surface unrelated to #258
  ([manifest](https://github.com/cloudmanic/herdr-plus/blob/f38df3570bea8f7ca71dc1ba11bce3b123d14402/herdr-plugin.toml)).

**Assessment:** strongest candidate, but not reasonable to adopt/configure under
the current acceptance criteria. A viable upstream path would first need aliases,
an aggregate user file, central project matching, command handoff after popup
closure, and safe value interpolation. That is too much prerequisite product work
for a behavior-preserving extraction.

### 2. vjeantet/herdr-palette

**Verified strengths**

- A broad palette over Herdr built-ins, all installed plugin actions, user
  commands, and user prompts. Destructive built-ins use confirmation defaulting
  to No; plugin actions are handed off after popup close
  ([README](https://github.com/vjeantet/herdr-palette/blob/8f4c6bf5cf6102cec31cfbd5a09ccbb4dcaceb44/README.md)).
- User commands and prompts live in one plugin-owned `config.toml`, with stable
  per-entry IDs. A user command supports argv, placement, hold-on-success, fixed
  cwd, and one optional free-text input
  ([schema](https://github.com/vjeantet/herdr-palette/blob/8f4c6bf5cf6102cec31cfbd5a09ccbb4dcaceb44/src/custom.rs#L53-L121),
  [loader](https://github.com/vjeantet/herdr-palette/blob/8f4c6bf5cf6102cec31cfbd5a09ccbb4dcaceb44/src/custom.rs#L130-L190)).
- Commands act from the pane/tab/workspace that opened the palette. The socket
  client explicitly closes the popup before plugin-action dispatch
  ([popup close](https://github.com/vjeantet/herdr-palette/blob/8f4c6bf5cf6102cec31cfbd5a09ccbb4dcaceb44/src/ipc.rs#L131-L141)).
- Linux/macOS, Herdr >= 0.8.0; install fetches and verifies a release binary and
  falls back to Cargo. Latest verified release
  [v0.2.2 on 2026-08-31](https://github.com/vjeantet/herdr-palette/releases/tag/v0.2.2),
  with source activity on 2026-09-10. The repository is MIT despite GitHub's API
  classifying the attribution-bearing file as “Other”
  ([license text](https://github.com/vjeantet/herdr-palette/blob/8f4c6bf5cf6102cec31cfbd5a09ccbb4dcaceb44/LICENSE)).

**Verified conflicts and gaps**

- No shortcut/alias field. The fuzzy matcher takes over on the first query;
  only the last-used row affects empty-query order
  ([row ordering](https://github.com/vjeantet/herdr-palette/blob/8f4c6bf5cf6102cec31cfbd5a09ccbb4dcaceb44/src/rows.rs#L1-L55)).
- No global/project origins or project visibility rules. User commands are one
  global catalog; `cwd` is either the origin pane by default or one fixed absolute
  directory.
- User commands support one free input but not a declared static/dynamic select,
  multiline form, or nested command type.
- User commands are argv-only and open a split, tab, or zoomed runner. They do
  not reproduce shell pipelines, `pane_run`, overlay replacement, workspace
  picking, or the current pause behavior without wrapper scripts.
- No smart-close action.

**Assessment:** the best alternative if one-file configuration matters more than
behavioral parity. It is not a configuration-only replacement for #258.

### 3. arjenblokzijl/herdr-launcher

**Verified strengths**

- Declarative TOML workflows with free text, multiline fields, and dynamic fuzzy
  `choices_command` fields. Values are passed through environment variables
  rather than interpolated into the shell
  ([README](https://github.com/arjenblokzijl/herdr-launcher/blob/40b9559d748eaa68cee6d1d34472fb829aca1cf6/README.md)).
- The launcher carries the invoking cwd into its UI and workflows
  ([source](https://github.com/arjenblokzijl/herdr-launcher/blob/40b9559d748eaa68cee6d1d34472fb829aca1cf6/src/main.rs#L746-L784)).
- Linux/macOS, Herdr >= 0.7.0, MIT. Source reached manifest version 0.3.0 on
  2026-07-10
  ([manifest](https://github.com/arjenblokzijl/herdr-launcher/blob/40b9559d748eaa68cee6d1d34472fb829aca1cf6/herdr-plugin.toml),
  [license](https://github.com/arjenblokzijl/herdr-launcher/blob/40b9559d748eaa68cee6d1d34472fb829aca1cf6/LICENSE)).

**Verified conflicts and gaps**

- One file or bundle per workflow, not one aggregate config file. No native
  project/global visibility or repo-local lookup; every workflow is globally
  listed and runs from the current cwd.
- No shortcut/alias tier and no smart-close action.
- A workflow ultimately runs one shell command. It can call Herdr, but does not
  supply the current dispatch modes or command grouping.
- Install requires Cargo (directly or through mise). The latest GitHub release is
  [v0.2.0 from 2026-07-01](https://github.com/arjenblokzijl/herdr-launcher/releases/tag/v0.2.0),
  behind the manifest's 0.3.0, so the tested-release policy is incomplete.

**Assessment:** good workflow/form engine and a useful source of design ideas;
not a general command-palette replacement.

### 4. speardragon/herdr-command-center

**Verified strengths**

- Exactly one atomically edited `commands.toml`, with stable command IDs and
  stable one-character slots. Supports detached shell commands, commands typed
  into the focused pane, and plugin actions
  ([README and schema](https://github.com/speardragon/herdr-command-center/blob/739a0a4dc5b9efc3a82bd3cf0e981c4dd3c3a97e/README.md)).
- Preserves origin cwd and refuses to type into an agent-owned pane
  ([executor](https://github.com/speardragon/herdr-command-center/blob/739a0a4dc5b9efc3a82bd3cf0e981c4dd3c3a97e/src/executor.mjs#L63-L103)).
- Explicitly hands work to a detached runner after the popup exits and retries
  `ui_busy` during teardown
  ([executor](https://github.com/speardragon/herdr-command-center/blob/739a0a4dc5b9efc3a82bd3cf0e981c4dd3c3a97e/src/executor.mjs#L105-L140)).
- Linux/macOS, Herdr >= 0.7.5, MIT
  ([manifest](https://github.com/speardragon/herdr-command-center/blob/739a0a4dc5b9efc3a82bd3cf0e981c4dd3c3a97e/herdr-plugin.toml),
  [license](https://github.com/speardragon/herdr-command-center/blob/739a0a4dc5b9efc3a82bd3cf0e981c4dd3c3a97e/LICENSE)).

**Verified conflicts and gaps**

- This is a fixed 36-slot grid, not fuzzy title search. Slots are a credible
  shortcut mechanism but do not preserve shortcut-before-title behavior.
- No project-scoped commands, per-command forms/selects, nested dispatch,
  workspace picker, or smart close.
- Requires Node.js >= 22 and npm; install runs `npm ci` and the test suite. The
  repository had source activity on 2026-08-19 but no GitHub Release, so it does
  not yet provide the tested-release/revision policy #258 requests.

**Assessment:** strongest smart handoff and one-file editor, but a different UX
and a much smaller command model.

### 5. vika2603/herdr-palette

**Verified strengths**

- Broad command surface: maintained Herdr operation catalog, installed plugin
  actions, the user's Herdr `[[keys.command]]`, and live workspace/tab/pane/agent
  targets. It forwards plugin invocation context and has its own target pickers,
  input fields, confirmations, and recent ordering
  ([README](https://github.com/vika2603/herdr-palette/blob/32dc165fa6fdedb799d85680d61988c950502a15/README.md)).
- User commands remain in Herdr's single `config.toml`. Shell, pane, and popup
  bindings are reproduced over the API and run in the focused cwd
  ([custom command source](https://github.com/vika2603/herdr-palette/blob/32dc165fa6fdedb799d85680d61988c950502a15/internal/palette/custom.go#L23-L129)).
- Linux/macOS, Herdr >= 0.9.0. Go builds are preferred; matching checksummed
  binaries are the fallback. Latest verified release
  [v0.1.0 on 2026-09-11](https://github.com/vika2603/herdr-palette/releases/tag/v0.1.0),
  with source activity on 2026-09-13. MIT
  ([manifest](https://github.com/vika2603/herdr-palette/blob/32dc165fa6fdedb799d85680d61988c950502a15/herdr-plugin.toml),
  [license](https://github.com/vika2603/herdr-palette/blob/32dc165fa6fdedb799d85680d61988c950502a15/LICENSE)).

**Verified conflicts and gaps**

- Custom commands use Herdr keybinding configuration, which has no current
  command groups, shortcuts, selects/forms, project origins, or nested run types.
- Search uses one fuzzy surface plus recent ordering; no deterministic alias tier
  outranks title matches.
- The plugin's own optional window/color config is a second file.
- No smart-close action.

**Assessment:** excellent Herdr-wide action/navigation palette, but migrating the
personal command set would discard too much of its schema.

### 6. ramarivera/herdr-palette

**Verified strengths**

- Combines keybindings, plugin actions, Herdr operations, workspaces, tabs, and
  agents in a Rust/Ratatui tree or flat fuzzy list. It inherits Herdr theme data
  and executes supported rows in the origin cwd
  ([README](https://github.com/ramarivera/herdr-palette/blob/0478a908afd4f0775d8165765dcdc7d70a6e5ac1/README.md),
  [dispatch](https://github.com/ramarivera/herdr-palette/blob/0478a908afd4f0775d8165765dcdc7d70a6e5ac1/src/dispatch.rs#L197-L218)).
- Linux/macOS, Herdr >= 0.7.0, MIT
  ([manifest](https://github.com/ramarivera/herdr-palette/blob/0478a908afd4f0775d8165765dcdc7d70a6e5ac1/herdr-plugin.toml),
  [license](https://github.com/ramarivera/herdr-palette/blob/0478a908afd4f0775d8165765dcdc7d70a6e5ac1/LICENSE)).

**Verified conflicts and gaps**

- User `[[keys.command]]` shell/pane entries are deliberately reference-only;
  Enter cannot dispatch them
  ([source](https://github.com/ramarivera/herdr-palette/blob/0478a908afd4f0775d8165765dcdc7d70a6e5ac1/src/items.rs#L135-L165)).
- Search fuzzy-matches title, subtitle, category, and keys in one haystack. A key
  is not a stable tier above title
  ([source](https://github.com/ramarivera/herdr-palette/blob/0478a908afd4f0775d8165765dcdc7d70a6e5ac1/src/items.rs#L96-L110)).
- No user forms/selects, project/global origins, or smart close.
- Install builds with Cargo. The repository had no GitHub Release when checked;
  the latest cloned source commit was 2026-07-09, so a release-pinned install
  policy is not available.

**Assessment:** useful read/navigation layer, but it fails the first acceptance
criterion for personal command dispatch.

## Packaging, IDs, and lifecycle

| Candidate | Plugin/action ID to bind | Declared support and dependencies | Release state checked 2026-09-16 | License |
|---|---|---|---|---|
| herdr-plus | `cloudmanic.herdr-plus.quick-actions` | Herdr >= 0.7.0; Linux/macOS/Windows; prebuilt binary or Go, with Go required for Windows plugin install | v0.1.24, 2026-08-28; later source activity 2026-09-04 | MIT |
| vjeantet palette | `vjeantet.palette.open` | Herdr >= 0.8.0; Linux/macOS; checksummed binary with Cargo fallback | v0.2.2, 2026-08-31; later source activity 2026-09-10 | MIT with upstream attribution |
| arjenblokzijl launcher | `arjenblokzijl.herdr-launcher.pick` | Herdr >= 0.7.0; Linux/macOS; Cargo or mise Rust toolchain | latest release v0.2.0, 2026-07-01; source manifest is 0.3.0 | MIT |
| Command Center | `cdragon.command-center.open` | Herdr >= 0.7.5; Linux/macOS; Node.js >= 22 and npm | no GitHub Release; source manifest 1.2.0, activity 2026-08-19 | MIT |
| vika2603 palette | `herdr.palette.open` (`toggle`, `goto`, and `back` also exist) | Herdr >= 0.9.0; Linux/macOS; checksummed binary or Go | v0.1.0, 2026-09-11; later source activity 2026-09-13 | MIT |
| ramarivera palette | `ramarivera.palette.open` | Herdr >= 0.7.0; Linux/macOS; Cargo | no GitHub Release; latest cloned source commit 2026-07-09 | MIT |

All candidate IDs differ from `seigi.command-palette.open`. Adoption therefore
has a straightforward but explicit migration path for the open binding: update
both entries in `home/private_dot_config/herdr/config.toml`. None supplies a
replacement ID for `seigi.command-palette.smart_close`, and any candidate-specific
pane invocation also requires rewriting the hardcoded lazygit entry. Extraction
can avoid all three migrations by retaining the current manifest IDs.

Herdr's own plugin lifecycle is adequate for the extracted package and every
candidate:

- `herdr plugin install owner/repo` clones, previews, builds, registers, and
  creates separate config/state directories.
- Reinstalling refreshes a GitHub-managed checkout; v1 has no separate update
  command.
- `herdr plugin uninstall <id-or-source>` unregisters and removes the managed
  checkout while preserving config/state.
- `--ref` pins a tested revision.
- Herdr rejects a plugin whose `min_herdr_version` exceeds the installed binary,
  and manifests declare supported platforms.

Primary source: [official install/link/build/storage
documentation](https://herdr.dev/docs/plugins/#install-and-link).

Adopting any candidate requires changing at least the two palette bindings in
`home/private_dot_config/herdr/config.toml` and any hardcoded plugin pane calls.
The current tree has four material caller sites:

- `cmd+shift+p` and `prefix+space` invoke `seigi.command-palette.open`;
- `cmd+w` invokes `seigi.command-palette.smart_close`;
- the lazygit quick command opens pane entrypoint `lazygit` on plugin
  `seigi.command-palette`.

Extraction can retain those IDs in the standalone manifest, making the package
source change invisible to callers. This is safer than adding shims and satisfies
the issue's “preserve IDs or migrate callers explicitly” clause directly.

## Gaps and limits

- The official marketplace page is client-rendered and very large. Discovery
  covered its command-palette search results, the 26-entry awesome-herdr category,
  and additional exact-name searches; it did not manually audit all 1,180
  marketplace repositories.
- Repository activity and release dates show recency, not a support guarantee.
  No maintainer responsiveness experiment or upstream feature request was made.
- No candidate was installed or invoked in the user's live Herdr session. The
  comparison is source-level because the requested task was research and this
  repository forbids host `chezmoi apply` by agents.
- Windows support was recorded where declared, but this repository's target
  behavior is macOS plus Linux CI. No Windows behavior was tested.
- “No repository-local clutter” needs one product clarification before any new
  central project-selector schema is designed. This note treats mandatory
  `.herdr-plus` files as a miss and the current optional, read-only `.herdr`
  discovery as existing behavior, not as the desired final central-config model.

## Extraction guidance

The candidate review changes how #258 should package the existing implementation,
even though it does not change the extract decision:

1. Keep `seigi.command-palette` and the current action/pane IDs.
2. Keep personal commands and shortcuts in the existing one-file chezmoi-owned
   path; the package must not seed or rewrite it.
3. Ship a manifest with explicit Python, `fzf`, Herdr-version, and OS
   requirements. A preflight should name missing runtime dependencies.
4. Use `herdr plugin install <repo> --ref <tested-tag>` in dotfiles. Update by
   changing the pinned tag/ref and reinstalling; remove with `plugin uninstall`.
5. Move the behavioral palette and smart-close tests with the implementation;
   retain only deployment/config/ID coverage here.
6. Publish checksummed releases and a clear source-install path. Herdr-plus and
   vjeantet provide the best models for this.
7. Preserve the current bare-value rejection. Do not copy herdr-plus's explicit
   `{{.Value}}` shell interpolation behavior.
8. Keep centrally configured project scoping, if desired, as separately accepted
   follow-up work rather than expanding the extraction ticket into a config
   redesign.
