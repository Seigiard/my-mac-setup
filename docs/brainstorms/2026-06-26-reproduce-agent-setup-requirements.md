---
date: 2026-06-26
topic: reproduce-agent-setup
---

# Reproduce agent setup (skills, agents, plugins) across reinstalls

## Summary

Make the full agent environment — skills, agents, and tool plugins for Claude
Code, OpenCode, and Pi — reproducible across machines and reinstalls through
chezmoi. Everything is handled as one of three kinds: *vendored files*
(committed and copied into place), *upstream-fetched* (chezmoi pulls from a
pinned upstream via `.chezmoiexternal.toml`), or *declarative reinstall*
(recorded in a manifest and reinstalled by the tool itself). No bespoke
management tool and no `npx skills`.

## Problem Frame

Agent configuration today comes from several uncoordinated paths and drifts:

- `home/.chezmoiexternal.toml` pulls 7 skills as GitHub archives into
  `~/.claude/skills/` (Claude only).
- `home/private_dot_claude/skills/` holds 4 authored skills (Claude only).
- Claude marketplace plugins (e.g. compound-engineering) ship skills **and**
  ~50 agents, tracked in `~/.claude/plugins/installed_plugins.json` and
  `known_marketplaces.json`.
- OpenCode carries skills as files, local plugins as files, and npm plugins
  declared in `opencode.json`.
- Pi carries standalone skills and agents as files in `~/.pi/agent/` and installs
  extensions via `pi install` (tracked in `settings.json` `packages[]`). An
  earlier uncoordinated `compound-engineering` install (files + a private
  manifest, never in `packages[]`) has been removed, leaving only tracked
  extensions and hand-authored agents.

The cost is concrete drift — `ce-brainstorm` is `3.14.3` on Claude but a May
copy on OpenCode — and no single place reproduces the setup on a fresh machine.

An earlier direction explored a declarative skill-management layer
(`Skillfile` + a custom CLI on top of `npx skills`). It was rejected after
verifying `npx skills` against `skills@1.5.13` source: its only replay command
(`experimental_install`) is project-scoped and reinstalls to universal agents
(no per-tool targeting), its global lockfile records only `skills add` installs,
and it adds a runtime dependency plus symlinks under `~/.agents` outside
chezmoi. The real need is **preservation and restore**, not a management CLI —
and chezmoi already reproduces files.

## Key Decisions

- **Reframe to reproduction, not management.** The goal is restoring the
  current skills/agents/plugins on a reinstall, with chezmoi as the umbrella —
  not a tool that curates or discovers skills.

- **Drop `npx skills` entirely.** The two capabilities it seemed to provide are
  already native: per-tool rollout is just placing files in each tool's dir via
  chezmoi, and third-party fetch+refresh is already done by
  `.chezmoiexternal.toml`. The only thing lost is catalog discovery
  (`skills find`) — a nice-to-have, not core.

- **Three restore mechanisms, nothing else.** *Vendored files* for skills,
  agents, and local plugins (commit the bytes, chezmoi copies them).
  *Upstream-fetched* for third-party skills (chezmoi pulls from a pinned ref).
  *Declarative reinstall* for marketplace/npm plugins (record what to install;
  the tool reinstalls). The R15 inventory uses exactly these three buckets.

- **Bundle-provided agents restore with their bundle, not separately.** Claude's
  ~50 `ce-*` agents and OpenCode's bundle agents come back when the bundle is
  reinstalled — they are never vendored as standalone files (that would
  duplicate and drift from the bundle). Only standalone, hand-authored agents
  are vendored.

- **All three tools are first-class targets.** Claude, OpenCode, and Pi each
  receive skills/agents and are reproduced by the same two mechanisms. Pi is not
  deferred — it already carries skills (`crit`, `web-perf`, `web-research`),
  agents, and a bundle install on disk.

- **Skills and agents are files.** All three tools discover skills by scanning
  directories for `SKILL.md`; agents are likewise files. Restore = copy.
  Selective per-tool rollout uses one canonical body in
  `home/.chezmoitemplates/` with thin per-tool include files — present where the
  skill should exist, absent where it shouldn't.

- **OpenCode self-installs its npm plugins.** OpenCode runs `bun install` at
  startup for entries in `opencode.json` → `plugin[]`. Committing `opencode.json`
  reproduces npm plugins; local plugins and skills are committed as files.

- **Claude marketplace plugins use a reinstall manifest.** The raw config files
  (`installed_plugins.json`, `known_marketplaces.json`) are non-portable
  (absolute paths, timestamps, machine state, project-scoped entries). Instead a
  small manifest records marketplace sources and user-scope plugins, and a run
  script reinstalls via `claude plugin marketplace add` / `claude plugin
  install`. The manifest is seeded by generating once from the `scope: user`
  entries in `installed_plugins.json`, then curated by hand.

- **Third-party skills stay re-fetched, not vendored.** They remain on
  `.chezmoiexternal.toml` (fetch + refresh from upstream) rather than copied into
  the repo — chosen for freshness and a thin repo, accepting the network
  dependency.

- **One canonical skill body, per-tool includes.** Multi-tool skills live once
  in `home/.chezmoitemplates/` with thin per-tool include files, rather than
  duplicated copies per tool — edited in one place, drift-free.

- **`oh-my-openagent.json` is out of scope.** Not preserved or managed, per the
  user's call. Accepted consequence: the `oh-my-openagent` plugin may need
  one-time reconfiguration (its agent→model mapping) on a fresh machine.

- **Track current by default; pin only by exception.** The goal is the same
  *set* of skills/plugins on every machine, kept current — not a frozen
  byte-snapshot. Sources track their normal channel (latest / a moving branch)
  and every machine updates uniformly; pin a source to an immutable ref only
  when a specific item must be frozen. The original drift (stale OpenCode copy
  of `ce-brainstorm`) was an update-consistency failure — nothing refreshed that
  copy — not an unpinned-version failure; uniform reinstall/refresh fixes it.
  Pinning every source would instead freeze you on old skills, the opposite of
  what's wanted. Tests verify presence and set-matches-manifest, not versions.

- **Pi is first-class by active use, not by disk presence.** Pi is included
  because all three tools are in active daily use (user-stated), not merely
  because files exist under `~/.pi/`.

## Requirements

### Skills and agents (vendored files)

- R1. Authored and third-party-vendored skills are committed and placed into
  each target tool's skills dir by chezmoi.
- R2. A skill intended for multiple tools has one canonical body in
  `home/.chezmoitemplates/`, included by a thin per-tool file; the skill exists
  in a tool only when its include is present (selective rollout).
- R3. Standalone agents (Claude `~/.claude/agents/`) are committed as files.
- R4. Third-party skills stay upstream-fetched via `.chezmoiexternal.toml` and
  refresh uniformly across machines so all stay current; they are not duplicated
  as vendored files. Pin a specific source to an immutable ref only when it must
  be frozen (exception, not default).
- R4b. Vendored and upstream-fetched skills must not collide on name within a
  single tool's skills dir (chezmoi reports inconsistent state on overlap); the
  inventory checks for name overlap.

### OpenCode plugins

- R5. `opencode.json` is committed as a template (`.tmpl` with an `.is_darwin`
  guard) so OpenCode self-installs npm plugins at startup, while macOS-only
  entries (the `@rynfar/meridian` `file://` brew path) are emitted only on
  darwin and never break a Linux/Docker apply.
- R5b. OpenCode npm plugins in `plugin[]` track their normal version channel;
  pin an exact version only for an item that must be frozen.
- R6. Local OpenCode plugins (`~/.config/opencode/plugins/*.ts,*.js`),
  standalone agents (`~/.config/opencode/agents/` that are not bundle-provided),
  and skill files (`~/.config/opencode/skills/`) are committed as files.
- R7. `node_modules/` is not committed.

### Claude marketplace plugins

- R8. A manifest records the portable essence: each marketplace's source
  (GitHub repo / git url) and each user-scope plugin to install
  (`plugin@marketplace`). Versions track upstream; pin only an item that must be
  frozen.
- R9. A run script reinstalls from the manifest via `claude plugin marketplace
  add` and `claude plugin install`, idempotently, and reports partial failures
  (e.g. marketplace added but install failed) rather than exiting as success.
- R10. Project-scoped plugins are excluded from global reproduction (they belong
  to specific project paths).
- R11. The raw `installed_plugins.json` / `known_marketplaces.json` are not
  committed verbatim.
- R11b. A drift check regenerates the manifest from live `installed_plugins.json`
  (user-scope) and diffs it against the committed manifest, surfacing plugins
  installed or removed outside the repo. Run on demand and in CI.

### Pi

- R12. Standalone Pi skills (`~/.pi/agent/skills/`) and hand-authored agents
  (`~/.pi/agent/agents/` not provided by an extension) are committed as files,
  on the same canonical-plus-include model as Claude and OpenCode.
- R13. Pi extensions are reproduced via `pi install <source>` from the committed
  `settings.json` `packages[]` (git/npm sources are portable), with `pi update`
  keeping them current. Any future bundle (e.g. a clean `compound-engineering`)
  must enter through `packages[]` to be reproduced — uncoordinated installs
  outside it are not covered and are pruned during consolidation (R15).
- R14. Pi secrets (`~/.pi/agent/auth.json`) are excluded from the committed set;
  any secret injection is guarded by `{{ if lookPath "op" }}` so a Docker/CI
  apply without 1Password does not fail.

### Consolidation and testing

- R15. Inventory only the items that will be reproduced (the input to the
  manifests), classifying each into one of the three buckets: vendored,
  upstream-fetched, declarative-reinstall. Not a standalone full audit.
- R16. Offline Docker verification (`make test-ubuntu` / `make test-docker`): a
  fresh container applies the repo and asserts vendored skills/agents land in
  each tool's expected dirs, the `.tmpl` files render on Linux, and the
  manifests/scripts are well-formed. Runs without 1Password or network. Covers
  vendored bytes + manifest shape only.
- R17. Live restore verification (real machine): a smoke step that runs the
  actual network-dependent paths — upstream skill fetch (R4), Claude
  `claude plugin install` (R9), OpenCode startup `bun install` (R5), Pi
  `pi install` (R13) — and confirms plugins land and function. Triggered after
  manifest changes; not part of offline CI. R16 and R17 together cover the full
  restore; neither alone does.

## Key Flows

- F1. Fresh-machine restore
  - **Trigger:** `chezmoi apply` on a new machine.
  - **Steps:** chezmoi places vendored skills/agents/local-plugins for all three
    tools → writes `opencode.json` (OpenCode self-installs npm plugins at next
    startup) → `run_onchange` reinstalls Claude marketplace plugins and Pi
    bundles from their manifests.
  - **Outcome:** Skills, agents, and plugins match the committed setup across
    Claude, OpenCode, and Pi.
  - **Covered by:** R1, R3, R5, R6, R8, R9, R12, R13.

- F2. Selective skill rollout
  - **Trigger:** A skill should be available on some tools but not others.
  - **Steps:** Canonical body lives once in `.chezmoitemplates/`; per-tool
    include files are added only for the intended tools.
  - **Outcome:** The skill appears only where its include exists.
  - **Covered by:** R2.

- F3. Claude plugin reinstall
  - **Trigger:** Manifest changes or fresh machine.
  - **Steps:** Script ensures each marketplace is added, then installs each
    user-scope plugin; re-running is a no-op when already present.
  - **Outcome:** Marketplace plugins (with their bundled agents) restored.
  - **Covered by:** R8, R9, R10.

## Acceptance Examples

- AE1. **Covers R2.** Given a skill with includes for Claude and OpenCode but not
  Pi, when `chezmoi apply` runs, then the skill exists in the Claude and
  OpenCode skills dirs and is absent from Pi's.
- AE2. **Covers R5.** Given `opencode.json` lists `oh-my-openagent`, when it is
  applied on a fresh machine and OpenCode starts, then OpenCode installs the
  plugin without manual steps.
- AE3. **Covers R9, R10.** Given the Claude manifest lists user-scope plugins and
  their marketplaces, when the reinstall script runs, then those marketplaces are
  added and plugins installed, and project-scoped plugins are not.
- AE4. **Covers R11.** Given a reinstall on a second machine, then no
  machine-specific absolute paths or timestamps from the original machine appear
  in committed Claude plugin state.

## Scope Boundaries

Deferred for later:

- Catalog/discovery UX for finding new skills.
- Supply-chain hardening (marketplace allowlisting, per-addition review gating,
  cryptographic checksum/signature enforcement, mandatory version pinning) —
  single-user personal dotfiles; trusting the chosen upstreams and updating
  uniformly is the proportionate boundary. Optional per-item pinning is the
  escape hatch when something must be frozen.

Outside this effort's identity:

- `npx skills` and any bespoke skill-management CLI.
- `oh-my-openagent.json` (agent→model config) — not preserved.
- Project-scoped Claude plugins — per-project, not global setup.
- Managing skills purely to roll them out to many tools at once — the goal is
  reproducing the chosen setup, not maximizing distribution.

## Dependencies / Assumptions

- `claude plugin` exposes non-interactive `install` and `marketplace`
  subcommands (verified present in the local CLI).
- OpenCode auto-installs `plugin[]` npm packages at startup into
  `~/.cache/opencode/node_modules/`.
- Brew-installed packages referenced by absolute path in OpenCode's `plugin[]`
  (e.g. `@rynfar/meridian` at `/opt/homebrew/lib/node_modules/...`) are present
  via the repo's Brewfile on macOS; the `.is_darwin` guard in R5 keeps this
  entry off Linux so a Docker apply doesn't break.
- Pi reinstalls extensions via `pi install <source>` / `pi update` from
  `settings.json` `packages[]` (confirmed); `pi list` enumerates them.
- `~/.pi/agent/auth.json` and other per-machine secrets are handled via the
  repo's existing 1Password/secret path, not committed.
- chezmoi remains the delivery mechanism; host constraint stands — never
  `chezmoi apply` on the host, validate via `make test-local` / `make
  test-ubuntu`.

## Outstanding Questions

Deferred to planning:

- **`pi-agent-browser` local path:** `settings.json` `packages[]` includes the
  absolute path `/Users/seigiard/.pi/agent/local/pi-agent-browser` — make
  portable or vendor the local package.
- **Out-of-repo install frequency:** how often plugins/skills are installed
  outside the repo — sets how valuable the R11b drift check is.

## Sources / Research

- `npx skills` (`skills@1.5.13`, `dist/cli.mjs`): `experimental_install` replays
  the project `skills-lock.json` to universal agents only (cli.mjs:4955); global
  lockfile records only `skills add` installs (cli.mjs:749);
  `listInstalledSkills` scans the filesystem (cli.mjs:2115); `copyDirectory`
  copies whole skill folders but there is no cross-component dependency
  resolution (cli.mjs:1849, 945) — a bundle's sibling agents never travel.
- Claude plugin state: `~/.claude/plugins/installed_plugins.json` (25 user-scope
  + 6 project-scope) and `known_marketplaces.json` carry absolute paths and
  timestamps (non-portable verbatim); `claude plugin install` / `claude plugin
  marketplace` provide a scriptable reinstall path.
- OpenCode (`sst/opencode`): plugins declared in `opencode.json` → `plugin[]`
  (npm names or `file://`), auto-installed via Bun at startup; skills discovered
  by scanning dirs for `SKILL.md`; local plugins loaded from
  `~/.config/opencode/plugins/`. Local `plugin[]` has `oh-my-openagent@latest`
  and an absolute brew path to `@rynfar/meridian`.
- Pi on disk: skills in `~/.pi/agent/skills/` (`crit`, `web-perf`,
  `web-research` — files), 58 agent files in `~/.pi/agent/agents/`, config
  (`settings.json`, `models.json`, `trust.json`, `chains/`), secret `auth.json`.
  `pi` CLI (`~/.local/bin/pi`) manages extensions: `pi install <source>` adds to
  `settings.json` `packages[]` (git/npm sources, one local abs-path), `pi list`,
  `pi update`. An earlier uncoordinated `compound-engineering` install (private
  `install-manifest.json` + 49 agent files, absent from `packages[]`) was
  removed; only `packages[]`-tracked extensions and 9 hand-authored agents
  remain.
- `oh-my-openagent` (`code-yeongyu/oh-my-openagent`): an OpenCode npm plugin
  installed via `opencode.json`; its `oh-my-openagent.json` holds agent→model
  mappings — out of scope here.
- Existing repo idioms: `home/.chezmoiexternal.toml` (7 skill archives),
  `home/private_dot_config/brewfiles/` + run-scripts (the manifest→apply pattern
  to mirror), `home/dot_zshenv.tmpl` (`OPENCODE_DISABLE_*` env vars).
