# 2026-10-11-brew-mise-macos-cli-versions

Date: **2026-10-11**. Host: macOS arm64. Query client: `mise 2026.10.7` (built 2026-10-09).

## Summary

Four selected packages have mise registry entries: Python, Claude Code, Codex, and 1Password CLI. Linear, Druk, and revmux have explicit GitHub backend evidence, but no registry shorthand. Executor and Memex need a separate CLI-versus-desktop decision.

Scope is limited to the eleven requested entries in `home/private_dot_config/brewfiles/empty_Brewfile.macos.tmpl`. “Latest Brew version” means the current stable formula or cask definition, not the installed version. “Latest mise version” means the observed backend response unless the cell says otherwise.

## Findings

| Package                        | Latest Brew version                     | Available in mise (name/backend)                                                                                                                                 | Latest mise version                                                                                                                     |
| ------------------------------ | --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `brew python`                  | **3.15.0**; alias of `python@3.15` [B1] | **Registry:** `python` → `core:python` [M1]                                                                                                                      | **3.15.0**, observed                                                                                                                    |
| `brew schpet/tap/linear`       | **3.0.0** [B2]                          | **Explicit backend, not registry:** `github:schpet/linear-cli`; version lookup and matching macOS CLI release assets verified [G1]                               | **3.0.0**, observed                                                                                                                     |
| `brew letstri/tap/druk`        | **1.39.0** [B3]                         | **Explicit backend, not registry:** `github:letstri/druk`; version lookup works and macOS CLI assets exist [G2]                                                  | **1.39.0** with `--minimum-release-age 0s`; **1.37.0** with default policy; both observed in successful authenticated follow-up queries |
| `brew ghostscript`             | **10.08.0** [B4]                        | No registry entry found; no equivalent explicit macOS backend verified                                                                                           | **Not established**                                                                                                                     |
| `brew librsvg`                 | **2.63.2** [B5]                         | No registry entry found; no equivalent explicit macOS backend verified                                                                                           | **Not established**                                                                                                                     |
| `cask claude-code`             | **2.1.287** [B6]                        | **Registry:** `claude` / `claude-code` → `aqua:anthropics/claude-code`; alternative `http:claude` [M2]                                                           | **2.1.296**, observed through aqua                                                                                                      |
| `cask codex`                   | **0.162.1** [B7]                        | **Registry:** `codex` → `aqua:openai/codex`; alternative `npm:@openai/codex` [M3]                                                                                | **0.162.1**, observed through aqua                                                                                                      |
| `cask executor`                | **1.6.10**, desktop bundle [B8]         | No registry entry. **CLI-only explicit backend evidence:** `github:UsefulSoftwareCo/executor`, with separate CLI assets; not a verified desktop replacement [G3] | **1.6.10**, observed repository release; CLI and desktop packaging differ                                                               |
| `cask umputun/apps/revmux`     | **0.2.6** [B9]                          | **Explicit backend, not registry:** `github:umputun/revmux`; same macOS CLI archives as the cask [G4]                                                            | **0.2.6**, observed                                                                                                                     |
| `cask nicosuave/tap/memex-app` | **0.27.0**, native GUI [B10]            | No registry entry or verified equivalent GUI setup. `github:nicosuave/memex` has **CLI** release evidence, not equivalence to `memex-app` [G5]                   | **No GUI result established**; **0.27.1** observed for the repository's CLI release                                                     |
| `cask 1password-cli`           | **2.40.0** [B11]                        | **Registry:** `1password` / `1password-cli` / `op` → `vfox:jdx/vfox-1password`; alternative `aqua:1password/cli` [M4]                                            | **2.40.0**, observed through vfox; aqua returned no versions                                                                            |

“Explicit backend” is a narrower claim than a registry entry or a successful installation. It means mise resolved the named repository's version and primary sources provide the relevant CLI artifact. No package installation, executable launch, dependency resolution, or default asset-selection test was performed.

## Package identity and asset evidence

- **Python:** `python.json` returned 404. Homebrew's `Aliases/python` points to `../Formula/p/python@3.15.rb`. The `python@3.15` JSON explicitly lists `python` among its aliases. [B1]
- **Linear:** the tap installs the `linear` binary from `schpet/linear-cli`. Release `v3.0.0` includes `linear-aarch64-apple-darwin.tar.xz` and `linear-x86_64-apple-darwin.tar.xz`. This is the CLI, not the Linear desktop cask. [B2] [G1]
- **Druk:** the tap installs `druk` from `druk-darwin-arm64.zip` or `druk-darwin-x64.zip`. Release `v1.39.0` was published on 2026-10-11 at 13:57:07 UTC. Authenticated follow-up queries returned 1.39.0 with the age filter disabled and 1.37.0 with the default policy. The latest release is available through mise but is too recent for the default 24-hour cutoff. [B3] [G2]
- **Ghostscript and librsvg:** the requested Brewfile uses `gs` and `rsvg-convert` as ImageMagick delegates. A similarly named library binding or a different SVG renderer does not establish equivalent executable availability. Absence from the searched registry is not proof that a custom backend is impossible.
- **Claude Code and Codex:** these casks download CLI distributions. Their matching mise registry entries are CLI packages too. The observed Claude Code backend is newer than the Brew cask at the time of this lookup. [B6] [B7] [M2] [M3]
- **Executor:** the cask downloads `executor-desktop-mac-arm64.dmg`. The repository's release also has `executor-darwin-arm64.zip` and `executor-darwin-x64.zip` for the CLI. The old `RhysSullivan/executor` release URL resolves to `UsefulSoftwareCo/executor`. Upstream documents CLI and desktop as different packaging of its runtime. A CLI-only mise setup would not preserve the desktop app or this repository's app-bundle CLI symlink by itself. [B8] [G3] [U1]
- **revmux:** although packaged as a cask, it declares `binary "revmux"`, not an app bundle. Its release archives are `revmux_0.2.6_darwin_arm64.tar.gz` and `revmux_0.2.6_darwin_amd64.tar.gz`. [B9] [G4]
- **Memex:** the cask installs `Memex.app` from `memex-app-0.27.0-macos-arm64.zip` and requires arm64 plus macOS Sonoma or later. Release `v0.27.1` has `memex-0.27.1-macos-arm64.tar.gz` but no `memex-app` archive. Its CLI version does not supersede the GUI cask version. Upstream documents the CLI and native macOS app separately. [B10] [G5] [U2]
- **1Password:** the registry names the `op` executable. The vfox version hook reads 1Password's official CLI release history. This is 1Password CLI, not the desktop password manager. [M4] [U3]

For explicit GitHub backends, mise documents that listing a version does **not** prove that its assets support the current platform. The artifact evidence above is therefore required in addition to the version query. Its `asset_pattern` option can select an exact archive when a release has multiple products. For Executor on arm64, the CLI artifact is `executor-darwin-arm64.zip`, not an `executor-desktop-*` archive. No asset-selection configuration was applied. [M6]

## Query record and limitations

The local `mise registry --json` output was checked against the current upstream registry directory and the four relevant registry files. Neither source supplied shorthand entries for Linear, Druk, Ghostscript, librsvg, Executor, revmux, or Memex. Registry status is separate from the generic GitHub backend's capabilities. [M1–M5]

The following environment settings were passed to the version queries:

```text
MISE_USE_VERSIONS_HOST=false
MISE_FETCH_REMOTE_VERSIONS_CACHE=0
MISE_AUTO_INSTALL=false
```

| Command | Exit status | Observed result |
| --- | --- | --- |
| `mise latest core:python` | 0 | `3.15.0` |
| `mise latest github:schpet/linear-cli` | 0 | `3.0.0` |
| `mise latest github:letstri/druk` | 0 | `1.37.0` |
| `mise ls-remote github:letstri/druk --no-versions-host` | 1 | GitHub HTTP 429 after retries; no version list |
| `mise latest aqua:anthropics/claude-code` | 0 | `2.1.296` |
| `mise latest aqua:openai/codex` | 0 | `0.162.1` |
| `mise latest github:UsefulSoftwareCo/executor` | 0 | `1.6.10` |
| `mise latest github:umputun/revmux` | 0 | `0.2.6` |
| `mise latest github:nicosuave/memex` | 0 | `0.27.1` |
| `mise latest aqua:1password/cli` | 0 | Empty stdout; warnings about missing `repo_owner` / `repo_name` and no versions found |
| `mise latest vfox:jdx/vfox-1password` | 0 | `2.40.0`; also cloned the vfox plugin |

An exit status of zero with empty output is not version evidence. The aqua failure does not negate the valid vfox registry route for 1Password.

**Unexpected host side effect:** the vfox query cloned `https://github.com/jdx/vfox-1password` at abbreviated revision `912327d`. This happened despite `MISE_AUTO_INSTALL=false`. Thus the investigation did not fully meet the requested no-install/no-change boundary: mise fetched a plugin, although it did not install the 1Password CLI. No cleanup command was run. Version queries may also update mise metadata caches. No tests, commits, or configuration edits were made.

The environment settings request upstream version lookups, but they do not establish that every backend bypassed every cache. A follow-up resolved the Druk rate-limit blocker: with the existing GitHub credential passed only through the child process environment, `mise latest github:letstri/druk --minimum-release-age 0s` exited zero with `1.39.0`, and the same command without the age override exited zero with `1.37.0`. URLs using `main`, `HEAD`, or `latest` are moving sources; the table records their responses on the date above. Homebrew API responses reported core revision `55e20cee59b7ded482b7f13704496832003259b7` and cask revision `4bef005febd2e6db1fbe9aff0721bed9bc912af9`.

## Primary sources

### Homebrew API and tap definitions

- **[B1]** [Python alias](https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Aliases/python), [python@3.15 JSON](https://formulae.brew.sh/api/formula/python@3.15.json).
- **[B2]** [schpet/tap/linear formula](https://raw.githubusercontent.com/schpet/homebrew-tap/HEAD/Formula/linear.rb).
- **[B3]** [letstri/tap/druk formula](https://raw.githubusercontent.com/letstri/homebrew-tap/HEAD/Formula/druk.rb).
- **[B4]** [Ghostscript JSON](https://formulae.brew.sh/api/formula/ghostscript.json).
- **[B5]** [librsvg JSON](https://formulae.brew.sh/api/formula/librsvg.json).
- **[B6]** [Claude Code cask JSON](https://formulae.brew.sh/api/cask/claude-code.json).
- **[B7]** [Codex cask JSON](https://formulae.brew.sh/api/cask/codex.json).
- **[B8]** [Executor cask JSON](https://formulae.brew.sh/api/cask/executor.json).
- **[B9]** [umputun/apps/revmux cask](https://raw.githubusercontent.com/umputun/homebrew-apps/HEAD/Casks/revmux.rb).
- **[B10]** [nicosuave/tap/memex-app cask](https://raw.githubusercontent.com/nicosuave/homebrew-tap/HEAD/Casks/memex-app.rb).
- **[B11]** [1Password CLI cask JSON](https://formulae.brew.sh/api/cask/1password-cli.json).

### mise registry and backend documentation

- **[M1]** [Python registry entry](https://github.com/jdx/mise/blob/main/registry/python.toml).
- **[M2]** [Claude registry entry](https://github.com/jdx/mise/blob/main/registry/claude.toml).
- **[M3]** [Codex registry entry](https://github.com/jdx/mise/blob/main/registry/codex.toml).
- **[M4]** [1Password registry entry](https://github.com/jdx/mise/blob/main/registry/1password.toml).
- **[M5]** [Current registry directory API](https://api.github.com/repos/jdx/mise/contents/registry), plus local `mise registry --json`.
- **[M6]** [GitHub backend documentation source](https://github.com/jdx/mise/blob/main/docs/dev-tools/backends/github.md), including asset selection and version-listing limitations.

### Upstream releases and product documentation

- **[G1]** [Linear latest-release API](https://api.github.com/repos/schpet/linear-cli/releases/latest), [v3.0.0](https://github.com/schpet/linear-cli/releases/tag/v3.0.0).
- **[G2]** [Druk latest-release API](https://api.github.com/repos/letstri/druk/releases/latest), [v1.39.0](https://github.com/letstri/druk/releases/tag/v1.39.0).
- **[G3]** [Executor latest-release API, original owner URL](https://api.github.com/repos/RhysSullivan/executor/releases/latest), [v1.6.10 at current owner](https://github.com/UsefulSoftwareCo/executor/releases/tag/v1.6.10).
- **[G4]** [revmux latest-release API](https://api.github.com/repos/umputun/revmux/releases/latest), [v0.2.6](https://github.com/umputun/revmux/releases/tag/v0.2.6).
- **[G5]** [Memex latest-release API](https://api.github.com/repos/nicosuave/memex/releases/latest), [v0.27.1](https://github.com/nicosuave/memex/releases/tag/v0.27.1).
- **[U1]** [Executor README: CLI and desktop packaging](https://github.com/UsefulSoftwareCo/executor/blob/main/README.md).
- **[U2]** [Memex README: CLI and native app](https://github.com/nicosuave/memex/blob/main/README.md).
- **[U3]** [vfox 1Password version hook](https://github.com/jdx/vfox-1password/blob/main/hooks/available.lua), which reads [official CLI v2 release history](https://app-updates.agilebits.com/product_history/CLI2).