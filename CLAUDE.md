# my-mac-setup

Reproducible dev environment for macOS (primary) and Linux (CI/Docker), managed by chezmoi. One repo → `chezmoi apply` → fully configured machine with tools, configs, and secrets.

## Project map

- `home/` — chezmoi source tree (`.chezmoiroot` = `home`); files map to `~/`
- `home/.chezmoiscripts/` — run scripts executed by chezmoi during apply (install Homebrew, etc.)
- `home/.chezmoiexternal.toml` — external archives/repos pulled by chezmoi (oh-my-zsh and its plugins, `fff-mcp`)
- `home/.chezmoiignore` — OS-conditional ignore rules (darwin-only vs linux-only files)
- `home/.chezmoi.yaml.tmpl` — template vars (`.name`, `.email`, `.is_darwin`, `.is_linux`)
- `home/private_dot_config/brewfiles/` — `Brewfile` (cross-platform) and `Brewfile.macos` (macOS-only)
- `tests/` — bashunit suites (`tests/bashunit/*_test.sh`, written against the house DSL `tests/bashunit/test-dsl.bash`); shared helpers in `tests/helpers/` (`common.bash`)
- `docker/` — Dockerfile and scripts for `make test-ubuntu`
- `browsers/` — browser extension configs (NOT managed by chezmoi)
- `configs/`, `docs/`, `macos-settings.md` — supplementary material

Reference docs (read on demand):

- `docs/solutions/` — documented learnings from past work (architecture patterns, design patterns, and diagnosed test failures), organized by category with YAML frontmatter (`module`, `tags`, `problem_type`); relevant when implementing or debugging in areas they cover
- `GLOSSARY.md` — shared domain vocabulary (entities, named processes, status concepts)
- `docs/agent-setup-inventory.md` — curated plugins/skills/agents for manual reinstall across Claude Code, OpenCode, Pi
- `docs/herdr-worktrees.md` — native Herdr worktree ownership and per-repository setup policy
- `docs/external-agent-cli-flags.md` — headless/one-shot invocation flags for external coding-agent CLIs
- `docs/machine-secrets.md` — age-encrypted machine secrets and SSH keys: editing, enrollment, revocation

## Agent skills

### Issue tracker

GitHub Issues in `Seigiard/my-mac-setup` are the sole repository work tracker. Use `gh` directly and follow `docs/agents/issue-tracker.md`.

### Triage labels

The canonical triage roles use native GitHub labels. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository: domain vocabulary lives at the root and architectural decisions live under `docs/adr/`. Read `docs/agents/domain.md` before you change an area: it names the vocabulary and the decisions to read first.

<important if="you need to run commands to build, test, lint, or run scripts">

| Command                                                | What it does                                                                                    |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| `make test-python`                                     | Run general Python contract tests                                                               |
| `make test-ubuntu`                                     | Full source render, disposable-home apply, and test suite in Docker                             |
| `make test-ubuntu-herdr`                               | Run the Ubuntu Docker suite through `herdr-run`                                                 |
| `make test-docker`                                     | Build + run full Docker test suite                                                              |
| `make test-suite`                                      | Post-apply suite against the already-applied `~/`; excludes `tests/bashunit/idempotent_test.sh` |
| `make test-templates`                                  | Focused source-render tests in Docker; included in `make test-ubuntu`                           |
| `make test-local`                                      | Diff this checkout's `home/` against the current home (dry-run, no changes)                     |
| `make lint`                                            | `lint-anti-slop`, `lint-yaml` and `lint-shell` (shellcheck plus the bats assertion check)        |
| `make shell-ubuntu`                                    | Interactive shell in Ubuntu container                                                           |
| `make build-docker`                                    | Build Docker image only                                                                         |
| `make clean`                                           | Remove Docker resources                                                                         |
| `tests/lib/bashunit -j 8 tests/bashunit/smoke_test.sh` | Run a single test file                                                                          |

</important>

<important if="you are about to run make test-local">

- Run `make test-local` as a one-shot command in the current Bash tool with enough transport time to reach its own terminal verdict; never run it in a Herdr pane.
- Invoke only the canonical target. Do not reconstruct its chezmoi command or add ad hoc flags.
- If the target stalls or transport expires, determine the previous process's state and diagnose the stall before retrying.

</important>

<important if="you are about to run make test-templates, make test-ubuntu, make test-docker, or make build-docker">

- Treat these targets as long-running Docker workloads, including cached runs. Read `~/.claude/shared/long-running-work.md` before launch.
- When `HERDR_ENV=1`, use `make test-ubuntu-herdr` for `make test-ubuntu`. Its label is `test-ubuntu-<checkout directory name>` (see the target in `Makefile`); use that label with `home/dot_local/bin/executable_herdr-run verdict <label>`. For other targets, use `home/dot_local/bin/executable_herdr-run <label> --cwd "$PWD" --wait -- make <target>`.
- Keep the workload free of the Bash tool's 120-second timeout. A bounded pane observation may stop waiting, but it must leave the workload running for the next check.
- Before retrying an interrupted workload, verify that its command and Docker children reached a terminal state, then state why a retry is safe.

</important>

<important if="you are about to run chezmoi apply or chezmoi init on the host">

- **Never** run `chezmoi apply` in this repo on the host — use `make test-local` (diff only) or `make test-ubuntu` (Docker) instead.
- **Never** run `chezmoi init` without `--config /tmp/chezmoi-test.yaml --config-path /tmp/chezmoi-test.yaml` outside Docker/CI — it overwrites the host's real config. Use `chezmoi_test_init()` from `tests/helpers/common.bash` in tests.

</important>

<important if="you are editing a config file that lives in the home directory (e.g., ~/.tmux.conf, ~/.config/...)">

Edit the **source** in `home/` (e.g., `home/dot_zshenv.tmpl`), not the live file in `~/`. Single source of truth, no drift. Run `chezmoi managed | grep <name>` to check if a file is tracked.

</important>

<important if="you edited a managed file and expect the change to take effect, or you ran chezmoi and got surprising results">

**chezmoi reads this checkout directly.** On every machine `sourceDir` in `~/.config/chezmoi/chezmoi.yaml` is `~/Projects/my-mac-setup/home`, so `chezmoi source-path ~/<live-path>` returns a path inside this repository. There are TWO copies of every managed file:

1. **This repo checkout** (`home/...`) — where you edit and commit. Raw `chezmoi` commands read it, uncommitted edits included.
2. **Live file** (`~/.config/...`, `~/.claude/...`) — what tools actually run. Only `chezmoi apply` writes it, and the user runs that, never an agent (see the rule above).

Consequence: an edit here is **not live until the user applies**. Never assume your edit took effect in-session; `make test-local` shows what an apply would change. A file whose source left the repository stays on disk after apply: name it and its `rm` command in the PR body.

If `chezmoi source-path` returns a path under `~/.local/share/chezmoi`, that machine still uses a separate clone: re-init it once with `chezmoi init --source ~/Projects/my-mac-setup` and delete the clone.

</important>

<important if="you are adding a new tool, app, config file, or directory">

Where new things go:

| Adding                         | Destination                                             |
| ------------------------------ | ------------------------------------------------------- |
| Cross-platform CLI tool        | `home/private_dot_config/brewfiles/Brewfile.tmpl`       |
| macOS-only cask/app            | `home/private_dot_config/brewfiles/empty_Brewfile.macos.tmpl` |
| Config file from `~/`          | `home/` via `chezmoi add`                               |
| External repo/archive          | `home/.chezmoiexternal.toml`                            |

Tool versions (e.g. node) change only by editing `home/private_dot_config/mise/config.toml`, never via `mise use --global` — that writes straight to the deployed file and diverges from this source.

Adding a managed config, step by step:

1. Check `home/.chezmoiexternal.toml` — paths managed there (e.g., `.oh-my-zsh`, `.local/bin/fff-mcp`) must not be duplicated in `home/`, or chezmoi reports "inconsistent state".
2. `chezmoi add ~/.config/tool` — creates the source file in `home/`.
3. Add a `.tmpl` suffix if the file needs OS branching or secrets; OS-specific files also need a rule in `home/.chezmoiignore`.
4. Apply the **test-oracle gate** before proposing coverage.
5. A new managed path is deployment-sensitive; follow `docs/agent-verification.md`.

`modify_` scripts (e.g., `modify_dot_claude.json`) read the existing file from stdin and output a modified version — don't treat them as regular templates.

</important>

<important if="you are retiring a managed file, or a deployed file whose source left the repository">

**Never add a path to `home/.chezmoiremove`.** A path listed there is deleted at every apply, so a file that later comes back under that path, managed or not, vanishes silently. Retired files are removed by hand on each machine: name the paths and the `rm` command in the PR body.

</important>

<important if="you are adding or changing agent skills">

- `home/private_dot_config/agent-skills/manifest` is the source of truth for selected upstream skills. Use `~/.local/bin/skills {add|remove|update|sync}` to manage the live global installation; `sync` applies declared wildcard exclusions but never removes other drift automatically.
- `home/private_dot_agents/skills/` is chezmoi's canonical storage for repository-owned model-invocable skills. The Skills CLI owns separate children in `~/.agents/skills` and records their ownership in its global lock; do not let either owner claim the same effective skill name.
- Client plugins retain non-skill functionality only. Restart Claude Code, OpenCode, and Pi after deployment or discovery changes.

</important>

<important if="you are adding or changing an explicit-only workflow">

An explicit-only workflow interrupts the current task and must run only after a direct user request. Keep one canonical description and body in `home/.chezmoitemplates/explicit-only-<name>-description.txt` and `home/.chezmoitemplates/explicit-only-<name>-body.md`.

Package the canonical content through three thin adapters:

- Claude Code: `home/private_dot_claude/skills/<name>/SKILL.md.tmpl`, with `disable-model-invocation: true`. Pi reads this deployed skill through its existing `~/.claude/skills` source and needs no separate adapter.
- Pi: `home/dot_pi/private_agent/skills/symlink_<name>.tmpl`, targeting the deployed Claude skill directory so Pi keeps the same explicit-only metadata.
- OpenCode: `home/private_dot_config/opencode/commands/<name>.md.tmpl`, which exposes a manual command. Never add the workflow under `home/private_dot_config/opencode/skills/`.

Use raw `include` with the explicit `.chezmoitemplates/<file>` path so literal Markdown and Go-template syntax remain data. Do not use `includeTemplate`, which executes the included content. Treat `$ARGUMENTS`, `$<digits>`, and unquoted `@path` as reserved OpenCode command syntax; a workflow that must preserve these sequences literally needs client-specific content instead.

Keep `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` in `home/dot_zshenv.tmpl` so OpenCode cannot discover the Claude-only adapters. Do not set `OPENCODE_DISABLE_EXTERNAL_SKILLS`; OpenCode must discover shared `~/.agents/skills` natively. After deployment, restart each client from the managed zsh environment before checking discovery. Add a workflow-specific smoke check for each new workflow's manual invocation boundary. Keep the OpenCode skill-discovery boundary check in `tests/bashunit/smoke_test.sh`. These template and managed-path changes are deployment-sensitive; follow `docs/agent-verification.md`.

</important>

<important if="you are working with templates, secrets, or the age-encrypted machine secrets">

- **Never** hardcode secrets in templates. Every exported API key lives in one age-encrypted file, `home/private_dot_config/secrets/encrypted_private_api-keys.yaml.age`, and reaches `~/.zshenv` through `include ... | decrypt | fromYaml` in `home/dot_zshenv.tmpl`. Edit it with `make edit-secrets`. The model, enrollment, and revocation are in `docs/machine-secrets.md`.
- Decryption needs a Machine identity at the path in `.chezmoi.config.age.identity`. Guard every use with the pattern in `dot_zshenv.tmpl` (`dig "age" "identity" "" .chezmoi.config`, then `stat`) so CI, Docker, the server, and a host config generated before the age block render without one; `.chezmoiignore` drops the decrypted target in the same condition.
- A new exported secret touches the age file, both branches of `dot_zshenv.tmpl`, and the full-fixture plumbing: `tests/helpers/chezmoi-unattended-targets.tsv`, `tests/helpers/common.bash`, `.github/workflows/test-dotfiles.yml`, and the build args in `docker/docker-compose.yml` and `docker/Dockerfile.ubuntu`. The Python contract test checks that each inventory row matches the fixtures its source template reads.
- Required env vars in CI: `CHEZMOI_NAME`, `CHEZMOI_EMAIL` (set in the GitHub workflow).

</important>

## Repository issues

For repository issue queries, lifecycle changes, or unresolved work, load the `repository-issues` skill. Apply its ownership gate before creating a GitHub issue, and use `gh` directly for queries and mutations.

<important if="you are deciding whether a test is warranted, or adding, changing, deleting, or reviewing tests">

- **Test-oracle gate:** Read `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md` first to decide whether a permanent test is warranted — including the zero-new-tests outcome — before designing one. It owns test design here; `~/.claude/shared/testing.md` owns the false-green rules that apply in every repository.
- Assert command status before inspecting output. Pair rejection fixtures with a nearby valid control that reaches the intended success path.
- Reach for exact `assert_output` and `assert_equal`. This suite's habit is `--partial`, which passes on wrong values too; keep it for genuinely unstable surrounding output, and match text that changes when the behavior breaks.
- Search existing coverage first and strengthen its best owner instead of duplicating the assertion. Put new coverage in the narrowest relevant suite; reserve `tests/bashunit/smoke_test.sh` for deployed cross-component behavior.
- Use `chezmoi_test_init()` from `tests/helpers/common.bash` instead of raw `chezmoi init`.

</important>

<important if="you are selecting or running checks, reusing evidence after edits, deciding whether to skip a broad check, preparing to publish, or verifying merge readiness">

- **Verification:** Read `docs/agent-verification.md` before selecting, running, reusing, or skipping checks. It defines risk classes, evidence validity, and publish and merge gates.

</important>

<important if="you are launching a revmux round, have read its findings, or are judging whether review context in this repository is complete">

- Until 2026-11-06 the default profile on this machine is `mixed-terra`: `mixed` plus a gpt-6.1-terra twin of each codex group, the one-week production trial for #576 (`docs/benchmarks/revmux-harness/trial-terra/`); nine agents, 6 + 3. Outside the trial the default is `mixed`, set in `~/.config/revmux/config`: each `lean` lens group once, on the model that found more of its gating findings across the `dual-model` archive, plus `docs+tests` on both models. Six agents. `dual-model` runs every group on both models at ten agents and stays available by name; the archive showed the second model adds findings and the second agent of a pair rarely does. `comprehensive` is the narrower roster here, not the full one. For the first round and for follow-up rounds, use the profile-selection policy in `code-review`.
- `.revmux/profile.md` is the reviewer calibration revmux injects into every agent of every round. The global ignore file excludes `.revmux/*`; this repository re-admits the profile with a `!.revmux/profile.md` line in its own `.gitignore`, because revmux resolves the profile from the process working directory, so it must reach every herdr worktree.
- It carries **weights, not facts** — how much something costs here, never what the repository contains. Anything an agent could establish by reading the repository belongs in the repository; only what changes a verdict belongs in the profile.
- **Update it when a round demonstrates that a weight was wrong.** That is the whole trigger: a finding missed, a severity rated by general instinct instead of this repository's own rules, a false positive on a deliberate convention, a mandatory gate never applied. A new `docs/solutions/` entry or ADR is a reason to check whether one of those happened, not a reason to add a line.
- Never write a round-local `input/profile.md`; it replaces the project file silently instead of extending it.

</important>
