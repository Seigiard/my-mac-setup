# 2026-10-11-brew-mise-cli-versions

Observed on **2026-10-11, 18:38–18:40 UTC**, on macOS ARM64 with **mise 2026.10.7**.

Scope: all **38** `brew` entries in the freshly read [cross-platform Brewfile](../../home/private_dot_config/brewfiles/Brewfile.tmpl), in source order, including entries behind the full-install guard. Tap declarations are not packages. The macOS Brewfile is outside this scope.

## Summary

- **31 packages have a registered mise name.** Six more have an explicit backend whose version lookup succeeded, but no registered short name. The remaining package is mise itself, which is the bootstrap tool.
- Four rows differ between Brew and mise's default selection: `lazygit`, `fzf`, `poppler`, and `imagemagick`. The first two differ because of the release-age policy. The other two differ at the conda backend.
- Version discovery does not prove that a package can replace Brew on every platform. In particular, the current `btop` aqua package supports Linux, not macOS.

## Method and interpretation

1. Read each core formula's `https://formulae.brew.sh/api/formula/<name>.json`, using `versions.stable` and `revision`. `delta` is an alias of `git-delta`; the alias URL returned 404, and the canonical JSON confirmed the alias. Brew revisions are shown as `_1` where applicable.
2. Read the actual tap formulas for `rgrc`, `bun`, and `memex`. Their links below are pinned to the observed tap commits.
3. Read the current [mise registry at commit `f0f41dc`](https://github.com/jdx/mise/tree/f0f41dc62d5702af68fe8269523b0274b047b68d/registry). Also inspected all 1,017 TOML files in that commit's registry archive for names and aliases. `zsh`, `git`, `mise`, `rgrc`, `memex`, `ouch`, and `procs` had no registered name or alias. A missing registry name does not mean that an explicit backend cannot query the package.
4. Query the installed mise with `mise latest <id> --minimum-release-age 0s` and `mise latest <id>`. These are observed backend results, not versions copied from an upstream release page. Initial zero-age calls used the equivalent `0` argument. Queries used `MISE_USE_VERSIONS_HOST=0`, `MISE_FETCH_REMOTE_VERSIONS_CACHE=0`, and `MISE_AUTO_INSTALL=0`. Most ran outside this checkout to avoid project configuration. No install, upgrade, or configuration-write command was run.
5. Confirm that `minimum_release_age` was unset and `minimum_release_age_excludes` was `[]`. The installed version's [settings source](https://github.com/jdx/mise/blob/v2026.10.7/settings.toml) documents a **24-hour default** for aqua, cargo, core, github, and npm, among other backends. **Conda and vfox have no default age cutoff.** Exact versions and lockfile versions bypass the age filter. See also [mise's release-age documentation](https://mise.jdx.dev/security.html#minimum-release-age).
6. Initial unauthenticated GitHub calls hit rate limits. Empty output with warnings was rejected even when the command exited zero. Affected queries were repeated successfully with the existing `gh` credential passed only in the child process environment. No credential value was written to this note.

**Table notation:** “default: same” means the separate default-policy query returned the same version. It is an observed selection result, not an independent audit of every release timestamp. “Explicit” means the full backend ID was queried successfully but the tool is not registered under a short name. All numeric mise versions below are observed `mise latest` output; none are upstream-only inferences. Registry links explain the mapping; Brew links supply the formula version.

## Complete comparison

| Brew package | Latest Brew version | Available in mise (name/backend) | Latest mise version |
| --- | --- | --- | --- |
| `zsh` | [5.9.2](https://formulae.brew.sh/api/formula/zsh.json) | **Explicit**, no registered name: `conda:zsh` ([channel](https://anaconda.org/conda-forge/zsh)) | **5.9.2**; default: same, no conda age cutoff |
| `starship` | [1.26.0](https://formulae.brew.sh/api/formula/starship.json) | [`starship`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/starship.toml) → `aqua:starship/starship` | **1.26.0**; default: same |
| `lazywalker/tap/rgrc` | [0.6.35](https://github.com/lazywalker/homebrew-tap/blob/ab592503e77b7df4c994d678b54b049750d08c63/Formula/rgrc.rb) | **Explicit**, no registered name: `github:lazywalker/rgrc` ([release](https://github.com/lazywalker/rgrc/releases/tag/v0.6.35)) | **0.6.35**; default: same |
| `git` | [2.56.0_1](https://formulae.brew.sh/api/formula/git.json) | **Explicit**, no registered name: `conda:git` ([channel](https://anaconda.org/conda-forge/git)) | **2.56.0**; default: same, no conda age cutoff; Brew `_1` is a packaging revision |
| `gh` | [2.102.0](https://formulae.brew.sh/api/formula/gh.json) | [`github-cli`, alias `gh`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/github-cli.toml) → `aqua:cli/cli` | **2.102.0**; default: same |
| `delta` | [0.20.1](https://formulae.brew.sh/api/formula/git-delta.json) | [`delta`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/delta.toml) → `aqua:dandavison/delta` | **0.20.1**; default: same |
| `lazygit` | [0.66.1](https://formulae.brew.sh/api/formula/lazygit.json) | [`lazygit`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/lazygit.toml) → `aqua:jesseduffield/lazygit` | **0.66.1** with age disabled; **0.66.0** by default |
| `mise` | [2026.10.8](https://formulae.brew.sh/api/formula/mise.json) | **Bootstrap**, not a useful move into its own tool registry; no registered `mise` tool | **N/A**; running mise was 2026.10.7, not the Brew latest |
| `ni` | [30.6.0](https://formulae.brew.sh/api/formula/ni.json) | [`ni`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/ni.toml) → `npm:@antfu/ni` | **30.6.0**; default: same |
| `node` | [26.11.1](https://formulae.brew.sh/api/formula/node.json) | [`node`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/node.toml) → `core:node` | **26.11.1**; default: same; latest, not an LTS selection |
| `oven-sh/bun/bun` | [1.4.3](https://github.com/oven-sh/homebrew-bun/blob/f698c7817c8bf40904fa009be1ca362a0d937ed4/Formula/bun.rb) | [`bun`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/bun.toml) → `core:bun` | **1.4.3**; default: same |
| `ripgrep` | [15.2.0](https://formulae.brew.sh/api/formula/ripgrep.json) | [`ripgrep`, alias `rg`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/ripgrep.toml) → `aqua:BurntSushi/ripgrep` | **15.2.0**; default: same |
| `bat` | [0.26.1](https://formulae.brew.sh/api/formula/bat.json) | [`bat`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/bat.toml) → `aqua:sharkdp/bat` | **0.26.1**; default: same |
| `jq` | [1.8.2](https://formulae.brew.sh/api/formula/jq.json) | [`jq`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/jq.toml) → `aqua:jqlang/jq` | **1.8.2**; default: same |
| `gitleaks` | [8.30.1](https://formulae.brew.sh/api/formula/gitleaks.json) | [`gitleaks`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/gitleaks.toml) → `aqua:gitleaks/gitleaks` | **8.30.1**; default: same |
| `age` | [1.3.2](https://formulae.brew.sh/api/formula/age.json) | [`age`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/age.toml) → `aqua:FiloSottile/age` | **1.3.2**; default: same |
| `yazi` | [26.9.1](https://formulae.brew.sh/api/formula/yazi.json) | [`yazi`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/yazi.toml) → `aqua:sxyazi/yazi` | **26.9.1**; default: same |
| `fd` | [10.5.0](https://formulae.brew.sh/api/formula/fd.json) | [`fd`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/fd.toml) → `aqua:sharkdp/fd` | **10.5.0**; default: same |
| `fzf` | [0.74.5](https://formulae.brew.sh/api/formula/fzf.json) | [`fzf`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/fzf.toml) → `aqua:junegunn/fzf` | **0.74.5** with age disabled; **0.74.4** by default |
| `zoxide` | [0.10.0](https://formulae.brew.sh/api/formula/zoxide.json) | [`zoxide`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/zoxide.toml) → `aqua:ajeetdsouza/zoxide` | **0.10.0**; default: same |
| `eza` | [0.23.5](https://formulae.brew.sh/api/formula/eza.json) | [`eza`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/eza.toml): `cargo:eza` queried; Linux default `aqua:eza-community/eza` also queried; macOS default is `vfox:jdx/vfox-eza` | **0.23.5** via cargo and aqua; default age: same on both; vfox lookup failed with HTTP 403 |
| `ouch` | [0.8.3](https://formulae.brew.sh/api/formula/ouch.json) | **Explicit**, no registered name: `github:ouch-org/ouch` ([release](https://github.com/ouch-org/ouch/releases/tag/0.8.3)) | **0.8.3**; default: same |
| `agent-browser` | [0.39.0](https://formulae.brew.sh/api/formula/agent-browser.json) | [`agent-browser`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/agent-browser.toml) → `aqua:vercel-labs/agent-browser` | **0.39.0**; default: same |
| `pi-coding-agent` | [1.1.0](https://formulae.brew.sh/api/formula/pi-coding-agent.json) | [`pi`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/pi.toml) → `aqua:earendil-works/pi`; registered alternatives: `github:earendil-works/pi`, `npm:@earendil-works/pi-coding-agent` | **1.1.0** via `pi`/aqua; default: same; alternatives not separately measured |
| `herdr` | [0.9.3](https://formulae.brew.sh/api/formula/herdr.json) | [`herdr`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/herdr.toml) → `aqua:herdrdev/herdr` | **0.9.3**; default: same |
| `nono` | [0.79.0](https://formulae.brew.sh/api/formula/nono.json) | [`nono`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/nono.toml) → `github:nolabs-ai/nono` | **0.79.0**; default: same |
| `nicosuave/tap/memex` | [0.27.1](https://github.com/nicosuave/homebrew-tap/blob/81cf1e2764acc25376e6050073af107871f03cd7/Formula/memex.rb) | **Explicit**, no registered name: `github:nicosuave/memex` ([release](https://github.com/nicosuave/memex/releases/tag/v0.27.1)) | **0.27.1**; default: same |
| `act` | [0.2.89](https://formulae.brew.sh/api/formula/act.json) | [`act`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/act.toml) → `aqua:nektos/act` | **0.2.89**; default: same |
| `shellcheck` | [0.11.0](https://formulae.brew.sh/api/formula/shellcheck.json) | [`shellcheck`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/shellcheck.toml) → `aqua:koalaman/shellcheck` | **0.11.0**; default: same |
| `btop` | [1.4.7](https://formulae.brew.sh/api/formula/btop.json) | [`btop`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/btop.toml) → `aqua:aristocratos/btop`; **current release is Linux-only in aqua** | **1.4.7** listed; default: same; not evidence of macOS installability |
| `procs` | [0.14.12](https://formulae.brew.sh/api/formula/procs.json) | **Explicit**, no registered name: `github:dalance/procs` ([release](https://github.com/dalance/procs/releases/tag/v0.14.12)) | **0.14.12**; default: same |
| `dust` | [1.2.6](https://formulae.brew.sh/api/formula/dust.json) | [`dust`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/dust.toml) → `aqua:bootandy/dust` | **1.2.6**; default: same |
| `duf` | [0.9.1](https://formulae.brew.sh/api/formula/duf.json) | [`duf`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/duf.toml) → `aqua:muesli/duf` | **0.9.1**; default: same |
| `ffmpeg` | [9.0.2_1](https://formulae.brew.sh/api/formula/ffmpeg.json) | [`ffmpeg`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/ffmpeg.toml) → `conda:ffmpeg` | **9.0.2**; default: same, no conda age cutoff; Brew `_1` is a packaging revision |
| `sevenzip` | [26.04](https://formulae.brew.sh/api/formula/sevenzip.json) | [`7zip`, alias `7z`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/7zip.toml) → `aqua:ip7z/7zip` | **26.04**; default: same |
| `poppler` | [26.10.0](https://formulae.brew.sh/api/formula/poppler.json) | [`poppler`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/poppler.toml) → `conda:poppler` | **26.09.0**; default: same, no conda age cutoff; behind Brew |
| `resvg` | [0.48.1](https://formulae.brew.sh/api/formula/resvg.json) | [`resvg`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/resvg.toml) → `aqua:linebender/resvg` | **0.48.1**; default: same |
| `imagemagick` | [7.1.2-33](https://formulae.brew.sh/api/formula/imagemagick.json) | [`imagemagick`](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/imagemagick.toml) → `conda:imagemagick` on macOS/Linux; registered aqua entry is Windows x64 only | **7.1.2_31**; default: same, no conda age cutoff; corresponds to upstream 7.1.2-31, behind Brew |

## Release-age differences

These upstream timestamps were read separately through GitHub's release API. They explain the measured difference; they do not substitute for the mise query.

| Tool | Upstream latest release | Published at (UTC) | Default mise selection | Earliest 24-hour eligibility for that release |
| --- | --- | --- | --- | --- |
| `lazygit` | [v0.66.1](https://api.github.com/repos/jesseduffield/lazygit/releases/latest) | 2026-10-11 09:26:26 | 0.66.0 | 2026-10-12 09:26:26 UTC |
| `fzf` | [v0.74.5](https://api.github.com/repos/junegunn/fzf/releases/latest) | 2026-10-11 02:39:32 | 0.74.4 | 2026-10-12 02:39:32 UTC |

Those future eligibility times assume unchanged release metadata and the default policy. They do not guarantee a future query result.

## Limits and side effects

- **No installation proof:** `mise latest` proves version resolution, not download selection, extraction, executable discovery, dependency resolution, or runtime behavior. Explicit GitHub rows are confirmed working version queries, not hypothetical backend strings. Their release assets were inspected: all four have macOS ARM64 and Linux artifacts. `memex` has no macOS Intel artifact in the observed release. No installation was attempted to validate those assets.
- **Platform scope:** conda queries are for this macOS ARM64 host. The [installed conda backend source](https://github.com/jdx/mise/blob/v2026.10.7/src/backend/conda.rs#L1072-L1129) queries the current platform plus `noarch`, rather than returning a universal version list. Linux may resolve different versions. The registry itself is cross-platform.
- **Build differences:** equal version strings do not establish equal codecs, delegates, libraries, or completions. This matters especially for `ffmpeg`, ImageMagick, and Poppler. A conda `zsh` also does not by itself change the login shell or shell registration.
- **btop:** the [current aqua recipe](https://github.com/aquaproj/aqua-registry/blob/main/pkgs/aristocratos/btop/registry.yaml) restricts recent releases to Linux. The [v1.4.7 assets](https://github.com/aristocratos/btop/releases/tag/v1.4.7) contain Linux builds only. The mise registry still carries a disabled installation-test comment about an older `.tar.gz` mismatch; the current aqua recipe already uses `.tar.gz`. That stale comment is not evidence of a present archive-format failure.
- **eza side effect:** contrary to the intended read-only scope, `mise latest eza` automatically cloned `jdx/vfox-eza` at `3c1fe13` into `~/.local/share/mise/plugins/eza`, despite `MISE_AUTO_INSTALL=0`. Its version lookup then failed with HTTP 403. No eza binary was installed. The plugin directory was left in place rather than removed without a separate cleanup decision. Subsequent eza queries used the registered explicit cargo and aqua backends. This is a limitation of treating plugin-backed version discovery as read-only.
- **Other writes:** version queries can refresh mise's metadata caches. No Brewfile, mise config, tool pin, or other repository configuration was changed. No tests or commits were run. This note is the only repository file added by this research.
- **Freshness:** Homebrew API and release links are live endpoints and can change after the observation window. Registry and tap links are commit-pinned. The installed mise executable was one patch behind the observed Brew formula, so this is a report of that executable's actual backend behavior, checked against the current registry, not a claim about an unrun mise version.
