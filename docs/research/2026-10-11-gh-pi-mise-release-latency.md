---
title: gh and Pi in mise - Release availability research
type: research
date: 2026-10-11
topic: gh-pi-mise-release-latency
status: complete
execution: read-only-source-research
---

# gh and Pi in mise

Both Brewfile entries have current mise registry routes. In the three sampled releases, Homebrew formula bumps followed GitHub CLI releases by about 1.5–2.7 hours and Pi npm publications by about 24–26 hours. These are measured publication-to-commit intervals, not measured end-user installation delays.

## Scope and observation date

Only `gh` and `pi-coding-agent` were investigated. The local source declares them in [`Brewfile.tmpl`](../../home/private_dot_config/brewfiles/Brewfile.tmpl), lines 46 and 85.

Sources were queried on **2026-10-11 UTC**; the host clock returned `2026-10-11T16:14:57Z`. Both Homebrew API responses report `generated_date: 2026-10-11`. No observation-date mismatch was found. No apps were installed or updated, no configs were changed, and no tests were run.

## Current versions and mise routes

| Brewfile entry | Upstream stable observed | Homebrew stable observed | Current mise registry mapping |
|---|---|---|---|
| `gh` | **2.102.0**, GitHub publication 2026-09-30 02:40:02 UTC | **2.102.0** | Canonical name `github-cli`, alias `gh`; first backend `aqua:cli/cli`, alternative `asdf:bartlomiejdanek/asdf-github-cli` |
| `pi-coding-agent` | **1.1.0**, npm `latest`; npm publication 2026-10-07 22:16:26.802 UTC; GitHub publication 22:26:31 UTC | **1.1.0** | Name `pi`; backends in order: `aqua:earendil-works/pi`, `github:earendil-works/pi`, `npm:@earendil-works/pi-coding-agent` |

Sources: [gh release](https://github.com/cli/cli/releases/tag/v2.102.0), [gh formula API](https://formulae.brew.sh/api/formula/gh.json), [Pi npm metadata](https://registry.npmjs.org/@earendil-works/pi-coding-agent), [Pi release](https://github.com/earendil-works/pi/releases/tag/v1.1.0), [Pi formula API](https://formulae.brew.sh/api/formula/pi-coding-agent.json).

Registry mappings are pinned to mise commit `f0f41dc62d5702af68fe8269523b0274b047b68d`: [github-cli](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/github-cli.toml), [pi](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/registry/pi.toml). These are current upstream mappings, not a claim about the locally installed mise version.

### What can move

- **gh:** the existing registry alias is a direct candidate. Aqua downloads upstream release binaries. Its recipe covers macOS and Linux and uses a version-based asset template, checksums, and GitHub artifact attestations. The latest release includes both macOS arm64 and amd64 ZIPs; their uploads completed before release publication. Sources: [pinned aqua recipe](https://github.com/aquaproj/aqua-registry/blob/525d9c1b2f8dc064e66fc8e8b31169df3d689609/pkgs/cli/cli/registry.yaml), [release API and asset timestamps](https://api.github.com/repos/cli/cli/releases/tags/v2.102.0).
- **Pi:** `pi` selects the Aqua binary route first in the current registry. The latest release includes macOS arm64/x64 and Linux arm64/x64 archives with the names used by the recipe. Sources: [pinned aqua recipe](https://github.com/aquaproj/aqua-registry/blob/525d9c1b2f8dc064e66fc8e8b31169df3d689609/pkgs/earendil-works/pi/registry.yaml), [release API and assets](https://api.github.com/repos/earendil-works/pi/releases/tags/v1.1.0).
- **Pi via npm:** the explicit identifier is `npm:@earendil-works/pi-coding-agent`. This follows the same package source as the current Homebrew formula, whose tarball URL uses the `@earendil-works` scope. The package exposes `pi` and requires Node.js **>=22.19.0**. Mise's npm backend installs packages in separate directories; a Node runtime must still be available. Sources: [package metadata](https://registry.npmjs.org/@earendil-works/pi-coding-agent/latest), [Homebrew API](https://formulae.brew.sh/api/formula/pi-coding-agent.json), [official npm backend docs](https://mise.jdx.dev/dev-tools/backends/npm.html).

These are source-backed migration candidates, not validated installations. The short name for Pi is `pi`, not the Brew formula name. An explicit npm backend makes the desired distribution channel clear.

## Matching release-to-Homebrew samples

All timestamps below are UTC. “Bump” means the version-change commit's **committer date**, as returned by GitHub. “Bottle” means the first following bottle-update commit for that version in the returned history; it excludes later rebuilds. Each bump and bottle timestamp links to its commit.

### GitHub CLI: GitHub publication to Homebrew commit

| Version | Upstream published | Formula bump | Bump interval | First bottle update | Bottle interval |
|---|---|---|---|---|---|
| [2.102.0](https://github.com/cli/cli/releases/tag/v2.102.0) | 2026-09-30 02:40:02 | [09-30 05:09:53](https://github.com/Homebrew/homebrew-core/commit/ae25606830bfbd094fce6cd5f6053f0451aca261) | 2h 29m 51s | [09-30 06:31:01](https://github.com/Homebrew/homebrew-core/commit/8c2afd1f3f499ac2a1c3d7ea16495fdb69267f91) | 3h 50m 59s |
| [2.101.0](https://github.com/cli/cli/releases/tag/v2.101.0) | 2026-09-15 14:24:34 | [09-15 17:08:13](https://github.com/Homebrew/homebrew-core/commit/03aa0584b6de434dcc63d36161dc9976bdd4458f) | 2h 43m 39s | [09-15 17:29:20](https://github.com/Homebrew/homebrew-core/commit/60a2bfa61b862ff2459fff6a2e254679bb3cce8b) | 3h 04m 46s |
| [2.100.0](https://github.com/cli/cli/releases/tag/v2.100.0) | 2026-09-03 15:43:20 | [09-03 17:16:25](https://github.com/Homebrew/homebrew-core/commit/e522b2af80a05c5da529315982349a72178d0dc5) | 1h 33m 05s | [09-03 17:39:51](https://github.com/Homebrew/homebrew-core/commit/87c47e10a37da00acffc388a750c9b74339eed15) | 1h 56m 31s |

API sources: [three releases](https://api.github.com/repos/cli/cli/releases?per_page=3), [formula history](https://api.github.com/repos/Homebrew/homebrew-core/commits?path=Formula/g/gh.rb&per_page=12).

### Pi: npm publication to Homebrew commit

The npm publication is the comparison baseline because Homebrew packages that npm tarball. Intervals are rounded to the nearest second.

| Version | npm published | Formula bump | Bump interval | First bottle update | Bottle interval |
|---|---|---|---|---|---|
| 1.1.0 | 2026-10-07 22:16:26.802 | [10-08 23:37:08](https://github.com/Homebrew/homebrew-core/commit/d53b95825c2d12d3db7675008afefcd920f9f04f) | 25h 20m 41s | [10-09 01:53:01](https://github.com/Homebrew/homebrew-core/commit/3d179dd217dadbbfe338db270a8efd5b6cd843e0) | 27h 36m 34s |
| 1.0.4 | 2026-10-05 21:51:59.920 | [10-06 23:47:09](https://github.com/Homebrew/homebrew-core/commit/552f275f6f929722b6e421e50746d1b1ea3c7383) | 25h 55m 09s | [10-07 00:07:37](https://github.com/Homebrew/homebrew-core/commit/c922865f6616bcaefb2a30626d1bedccf6362c9a) | 26h 15m 37s |
| 1.0.3 | 2026-10-05 08:37:00.736 | [10-06 08:50:42](https://github.com/Homebrew/homebrew-core/commit/267206f63df7a91ddd9749884d3d012800d4b9cd) | 24h 13m 41s | [10-06 10:05:18](https://github.com/Homebrew/homebrew-core/commit/def66a537646c6d4a693afdfb1857e49b9048f6e) | 25h 28m 17s |

API sources: [npm `time` entries and dist-tags](https://registry.npmjs.org/@earendil-works/pi-coding-agent), [formula history](https://api.github.com/repos/Homebrew/homebrew-core/commits?path=Formula/p/pi-coding-agent.rb&per_page=12).

For the Aqua/GitHub route, the matching GitHub publications were **2026-10-07 22:26:31**, **2026-10-05 22:03:50**, and **2026-10-05 08:38:23** respectively. They followed npm publication by about 10m 04s, 11m 50s, and 1m 22s. Source: [Pi releases API](https://api.github.com/repos/earendil-works/pi/releases?per_page=4).

## How quickly can mise see a version?

Mise does not need a per-version Homebrew formula bump for these routes:

- Aqua's version listing reads GitHub release metadata and applies its package recipe. Both recipes have a catch-all version rule and templated artifact names. An ordinary release with the same asset layout does not require a new recipe for its version number. Sources: [pinned Aqua backend](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/src/backend/aqua.rs#L331-L395), [release-list implementation](https://github.com/jdx/mise/blob/f0f41dc62d5702af68fe8269523b0274b047b68d/src/backend/aqua.rs#L5950-L5965), recipes above.
- The npm backend reads package metadata from the npm registry. Therefore Pi's npm publication is the upstream starting point for that route. Source: [official npm backend docs](https://mise.jdx.dev/dev-tools/backends/npm.html#private-registries).

This removes a packaging step; it does **not** prove instant client availability. Mise uses cached metadata, and Aqua recipes are bundled with mise by default. A changed asset layout can require a recipe update. Source: [official Aqua docs](https://mise.jdx.dev/dev-tools/backends/aqua.html#the-bundled-registry) and the backend source above.

## Automatic updates and actual freshness

The current official docs distinguish version discovery from automatic installation:

- `auto_update` is a global tool option. A duration sets the check interval; intervals below one hour become one hour. Shims and `mise exec` update a due tool before running it.
- With `mise activate`, a shell prompt starts due updates in the background. The next environment refresh after completion selects the new version. This repository uses `mise activate zsh` in [`dot_zshenv.tmpl`](../../home/dot_zshenv.tmpl).
- An optional `tool-update` user service checks hourly and respects each tool's interval. While it runs, launches and prompts do not perform their own updates.
- Exact version pins do not update. The repository currently pins OpenCode to `1.18.35` in [`mise/config.toml`](../../home/private_dot_config/mise/config.toml).

Source: [Automatic tool updates](https://mise.jdx.dev/dev-tools/#automatic-tool-updates).

**The default release-age delay matters to this comparison.** Aqua, GitHub, and npm backends default to `minimum_release_age = "24h"`. With a 24-hour update check interval, eligible updates normally arrive 24–48 hours after publication if the tool is used at least once per interval. Infrequent use can delay them further. A six-hour interval reduces that interval-based window to 24–30 hours under regular use; cache and installation delays can add time. `minimum_release_age = "0s"` disables the release-age delay for a selected tool.

Sources: [Minimum release age and backend defaults](https://mise.jdx.dev/security.html#minimum-release-age), [automatic update timing](https://mise.jdx.dev/dev-tools/#automatic-tool-updates).

Thus, direct upstream discovery does not imply faster default installation than Homebrew. In this sample, Homebrew's `gh` packaging commits were much earlier than mise's default 24-hour eligibility cutoff. Pi's Homebrew packaging took roughly the same time as that cutoff. Automatic installation is a separate benefit from earlier version availability.

## Limits and conclusion

- No historical mise visibility probe was available. The note does not assign mise a measured “zero-minute” delay or promise an exact time advantage.
- Git commit timestamps are not the time a PR reached the default branch, a bottle reached a CDN, or the Homebrew JSON API refreshed. PR merge times and distribution propagation were not measured.
- Three recent matching releases per app are a small sample, not a service guarantee. Release frequency was not used to infer packaging delay.
- Current upstream registry source does not prove that the installed mise contains those mappings. Runtime compatibility and CLI integrations were not tested.

**Conclusion:** both tools can plausibly move to mise. For `gh`, the sampled Homebrew lag is only a few hours, so version selection is a stronger reason to move than a large freshness gain. For Pi, a direct npm or upstream-binary route removes a formula step that took roughly a day in all three samples. On the observation date, Homebrew and upstream already have the same stable versions for both tools.
