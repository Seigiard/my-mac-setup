# 2026-10-11-brew-mise-desktop-versions

Snapshot date: 2026-10-11.

## Summary

The source contains 34 in-scope casks: 31 applications and three fonts. None has a confirmed mise distribution of the same macOS application or installed font in the registries checked. Similar CLI names do not establish desktop application availability.

## Scope and method

- Read [the Brewfile source](../../home/private_dot_config/brewfiles/empty_Brewfile.macos.tmpl) fresh. Include only `cask` declarations.
- Exclude `claude-code`, `codex`, `executor`, `umputun/apps/revmux`, `nicosuave/tap/memex-app`, and `1password-cli`, as requested. Formula declarations are outside this note.
- Read the Homebrew JSON API for all 33 in-scope official casks. The package links below point to those responses. Their `tap_git_head` was `4bef005febd2e6db1fbe9aff0721bed9bc912af9`.
- Read Spotifast from its third-party tap at commit `a8bcb2b8acc86184816d0830327c1a9495fe4f92`.
- Search all 1,012 top-level tool definitions in the [current upstream mise registry](https://github.com/jdx/mise/tree/f0f41dc62d5702af68fe8269523b0274b047b68d/registry), including aliases, backend names, and descriptions. This is a global registry check, not a check of locally installed tools.
- Also inspect relevant package definitions in the [official aqua registry](https://github.com/aquaproj/aqua-registry/tree/main/pkgs), downloaded from `main` on the snapshot date. GitHub API rate limiting prevented pinning this additional registry to a commit; its links are mutable.
- Make no installations or configuration changes. Do not treat an imagined custom installer, a generic download backend, or the ability to list upstream release tags as evidence that mise supports installing the desktop product.

The [mise registry documentation](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/docs/registry.md) explains that the registry maps short names to backends. An absent shorthand does not prove that every possible backend or third-party plugin is incapable of installing a product. Each mise release also bundles its own registry snapshot, so a local release can differ from upstream `main`.

## Versions

“Latest Brew version” is the exact current cask `version` value, including build components. It is not an independent claim about the vendor's newest release or download availability.

Availability labels:

- **No — absent:** no matching desktop/font entry in the current mise registry, and no supported equivalent distribution identified in the additional aqua check.
- **No — different product:** a related or same-name entry exists, but does not supply this desktop product. See the identity checks below.
- **N/A:** no latest mise version can be assigned to the same desktop/font distribution from the evidence collected. It does not mean the application has no upstream version.

| Package | Latest Brew version | Available in mise | Latest mise version |
| --- | --- | --- | --- |
| [font-jetbrains-mono-nerd-font](https://formulae.brew.sh/api/cask/font-jetbrains-mono-nerd-font.json) | `3.5.1` | No — absent | N/A |
| [font-iosevka-term-nerd-font](https://formulae.brew.sh/api/cask/font-iosevka-term-nerd-font.json) | `3.5.1` | No — absent | N/A |
| [font-symbols-only-nerd-font](https://formulae.brew.sh/api/cask/font-symbols-only-nerd-font.json) | `3.5.1` | No — absent | N/A |
| [ghostty](https://formulae.brew.sh/api/cask/ghostty.json) | `1.3.1` | No — absent | N/A |
| [kitty](https://formulae.brew.sh/api/cask/kitty.json) | `0.49.2` | No — absent | N/A |
| [zed](https://formulae.brew.sh/api/cask/zed.json) | `1.23.2` | No — different product | N/A |
| [obsidian](https://formulae.brew.sh/api/cask/obsidian.json) | `1.14.4` | No — absent | N/A |
| [raycast](https://formulae.brew.sh/api/cask/raycast.json) | `2.7.3.0` | No — absent | N/A |
| [marta](https://formulae.brew.sh/api/cask/marta.json) | `0.8.2` | No — absent | N/A |
| [ticktick](https://formulae.brew.sh/api/cask/ticktick.json) | `8.2.30,923` | No — absent | N/A |
| [linear](https://formulae.brew.sh/api/cask/linear.json) | `1.32.4` | No — absent | N/A |
| [finetune](https://formulae.brew.sh/api/cask/finetune.json) | `1.9.0` | No — absent | N/A |
| [setapp](https://formulae.brew.sh/api/cask/setapp.json) | `3.56.1,159,1789997229` | No — absent | N/A |
| [dropbox](https://formulae.brew.sh/api/cask/dropbox.json) | `272.4.3798` | No — different product | N/A |
| [syncthing-app](https://formulae.brew.sh/api/cask/syncthing-app.json) | `2.1.6-1` | No — different product | N/A |
| [1password](https://formulae.brew.sh/api/cask/1password.json) | `8.12.40` | No — different product | N/A |
| [karabiner-elements](https://formulae.brew.sh/api/cask/karabiner-elements.json) | `16.3.0` | No — absent | N/A |
| [the-unarchiver](https://formulae.brew.sh/api/cask/the-unarchiver.json) | `4.3.9,147,1742287964` | No — absent | N/A |
| [imageoptim](https://formulae.brew.sh/api/cask/imageoptim.json) | `1.9.3` | No — absent | N/A |
| [tailscale-app](https://formulae.brew.sh/api/cask/tailscale-app.json) | `1.104.1` | No — different product | N/A |
| [lunar](https://formulae.brew.sh/api/cask/lunar.json) | `6.11.0` | No — absent | N/A |
| [vorssaint](https://formulae.brew.sh/api/cask/vorssaint.json) | `3.4.1` | No — absent | N/A |
| [orbstack](https://formulae.brew.sh/api/cask/orbstack.json) | `2.2.3,20963` | No — absent | N/A |
| [spotify](https://formulae.brew.sh/api/cask/spotify.json) | `1.3.4.258` | No — different product | N/A |
| [crmne/tap/spotifast](https://github.com/crmne/homebrew-tap/blob/a8bcb2b8acc86184816d0830327c1a9495fe4f92/Casks/spotifast.rb) | `0.12.0` | No — absent | N/A |
| [iina](https://formulae.brew.sh/api/cask/iina.json) | `1.5.0` | No — absent | N/A |
| [transmission](https://formulae.brew.sh/api/cask/transmission.json) | `4.1.3` | No — absent | N/A |
| [helium-browser](https://formulae.brew.sh/api/cask/helium-browser.json) | `0.19.2.1` | No — absent | N/A |
| [zen](https://formulae.brew.sh/api/cask/zen.json) | `1.23.2b` | No — absent | N/A |
| [telegram](https://formulae.brew.sh/api/cask/telegram.json) | `13.0,283305` | No — absent | N/A |
| [slack](https://formulae.brew.sh/api/cask/slack.json) | `4.52.178` | No — different product | N/A |
| [zoom](https://formulae.brew.sh/api/cask/zoom.json) | `7.2.2.88465` | No — absent | N/A |
| [figma](https://formulae.brew.sh/api/cask/figma.json) | `126.9.13` | No — different product | N/A |
| [android-file-transfer](https://formulae.brew.sh/api/cask/android-file-transfer.json) | `5071136` | No — absent | N/A |

## Product identity checks

- **1Password:** the [mise `1password` entry](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/1password.toml) has aliases `1password-cli` and `op`. It exposes the `op` binary through CLI backends. It is not the `1password` desktop cask. The excluded CLI's version is intentionally not researched here.
- **Syncthing:** the [mise entry](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/syncthing.toml) targets `syncthing/syncthing`. The [cask](https://github.com/Homebrew/homebrew-cask/blob/4bef005febd2e6db1fbe9aff0721bed9bc912af9/Casks/s/syncthing-app.rb) instead downloads `syncthing/syncthing-macos` and installs `Syncthing.app`. Availability of the engine does not establish availability of the macOS wrapper.
- **Tailscale:** no Tailscale shorthand was found in the checked mise registry. The [aqua definition](https://github.com/aquaproj/aqua-registry/blob/main/pkgs/tailscale/tailscale/registry.yaml) does exist. On macOS it extracts `Distribution.pkg/Payload/Contents/MacOS/Tailscale` as a `tailscale` executable. That definition does not install the full desktop application and its system integration. A supported CLI artifact is not proof of support for `tailscale-app`.
- **Zed:** no editor entry was found in the mise registry. The [aqua `authzed/zed` definition](https://github.com/aquaproj/aqua-registry/blob/main/pkgs/authzed/zed/registry.yaml) explicitly describes a command-line tool for SpiceDB, not the Zed editor.
- **Linear:** no matching entry was found in either checked registry. The source also declares a separate `brew "schpet/tap/linear"` formula. That CLI declaration is not evidence for mise support of `cask "linear"`.
- **Spotify:** mise has [spotify-player](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/spotify-player.toml), a terminal player, and [spotify-downloader](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/spotify-downloader.toml). Neither is the Spotify desktop application or Spotifast.
- **Figma:** [figma-export](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/figma-export.toml) is a command-line asset exporter. It does not install Figma.
- **Slack:** aqua has [slackapi/slack-cli](https://github.com/aquaproj/aqua-registry/blob/main/pkgs/slackapi/slack-cli/registry.yaml) for developing Slack apps, plus terminal clients and notification tools. These do not install the Slack desktop application.
- **Dropbox:** the [rclone entry](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/rclone.toml) mentions Dropbox as a storage provider. It is not the Dropbox desktop client.

## Homebrew status and limitations

All 33 official cask API responses reported `deprecated: false` and `disabled: false`. Their deprecation and disable dates and reasons were null. The checked Spotifast tap source contains neither `deprecate!` nor `disable!`.

In particular, **do not label Android File Transfer deprecated or disabled in this snapshot**. Its [API response](https://formulae.brew.sh/api/cask/android-file-transfer.json) reports neither status. Its [pinned cask source](https://github.com/Homebrew/homebrew-cask/blob/4bef005febd2e6db1fbe9aff0721bed9bc912af9/Casks/a/android-file-transfer.rb) specifies version `5071136`, a Google download URL, and `requires_rosetta`. This establishes Homebrew metadata, not current vendor support or a successful installation. The DMG was not downloaded or installed.

The three font versions identify the Nerd Fonts release used by their casks, not the version of the original upstream typeface. Compound versions such as TickTick's `8.2.30,923` retain Homebrew's complete version string.

No installation tests were performed. The table is a source-based availability comparison, not a migration or runtime compatibility guarantee. The negative mise findings are bounded to the registries and distribution definitions checked; they are not a claim that custom tooling could never install these applications.
