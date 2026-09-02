# my-mac-setup

Reproducible dev environment for macOS (primary) and Linux (CI/Docker), managed by chezmoi. One repo → `chezmoi apply` → fully configured machine with tools, configs, and secrets.

## Project map

- `home/` — chezmoi source tree (`.chezmoiroot` = `home`); files map to `~/`
- `home/.chezmoiscripts/` — run scripts executed by chezmoi during apply (install Homebrew, etc.)
- `home/.chezmoiexternal.toml` — external archives/repos pulled by chezmoi (e.g., skills)
- `home/.chezmoiignore` — OS-conditional ignore rules (darwin-only vs linux-only files)
- `home/.chezmoi.yaml.tmpl` — template vars (`.name`, `.email`, `.is_darwin`, `.is_linux`)
- `home/private_dot_config/brewfiles/` — `Brewfile` (cross-platform) and `Brewfile.macos` (macOS-only)
- `tests/` — bashunit suites (`tests/bashunit/*_test.sh`, written against the house DSL `tests/bashunit/test-dsl.bash`); shared helpers in `tests/helpers/` (`common.bash`)
- `docker/` — Dockerfile and scripts for `make test-ubuntu`
- `browsers/` — browser extension configs (NOT managed by chezmoi)
- `configs/`, `docs/`, `macos-settings.md` — supplementary material

Reference docs (read on demand):

- `docs/solutions/` — documented learnings from past work (architecture and design patterns), organized by category with YAML frontmatter (`module`, `tags`, `problem_type`); relevant when implementing or debugging in areas they cover
- `CONCEPTS.md` — shared domain vocabulary (entities, named processes, status concepts)
- `docs/agent-setup-inventory.md` — curated plugins/skills/agents for manual reinstall across Claude Code, OpenCode, Pi
- `docs/herdr-worktrees.md` — native Herdr worktree ownership and per-repository setup policy
- `docs/external-agent-cli-flags.md` — headless/one-shot invocation flags for external coding-agent CLIs

<important if="you need to run commands to build, test, lint, or run scripts">

| Command | What it does |
|---|---|
| `make test-issues` | Strictly validate repository issues and run issue CLI tests |
| `make test-ubuntu` | Full test in Docker |
| `make test-docker` | Build + run full Docker test suite |
| `make test-suite` | Post-apply suite in parallel, host-safe files only. It keeps `tests/bashunit/idempotent_test.sh` excluded as redundant defense behind that file's `MMS_DISPOSABLE_HOME` guard. Asserts against the **already-applied** `~/`, not this checkout — an unapplied edit under `home/` is not covered and still goes green |
| `make test-templates` | Template tests in Docker; may rebuild images and take several minutes |
| `make test-local` | `chezmoi diff` (dry-run, no changes) |
| `make lint` | shellcheck |
| `make shell-ubuntu` | Interactive shell in Ubuntu container |
| `make build-docker` | Build Docker image only |
| `make clean` | Remove Docker resources |
| `tests/lib/bashunit -j 8 tests/bashunit/smoke_test.sh` | Run a single test file |

</important>

<important if="you are about to run make test-templates, make test-ubuntu, make test-docker, or make build-docker">

- Treat these targets as long-running Docker workloads, including cached runs. Read `~/.claude/shared/long-running-work.md` before launch.
- When `HERDR_ENV=1`, launch the workload in a visible sibling Herdr pane, persist its exit status as a terminal marker, and observe that marker before reporting a verdict.
- Keep the workload free of the Bash tool's 120-second timeout. A bounded pane observation may stop waiting, but it must leave the workload running for the next check.
- Before retrying an interrupted workload, verify that its command and Docker children reached a terminal state, then state why a retry is safe.

</important>

<important if="you are about to run chezmoi apply or chezmoi init on the host">

- **Never** run `chezmoi apply` in this repo on the host — use `make test-local` (diff only) or `make test-ubuntu` (Docker) instead.
- **Never** run `chezmoi init` without `--config /tmp/chezmoi-test.yaml --config-path /tmp/chezmoi-test.yaml` outside Docker/CI — it overwrites the host's real config. Use `chezmoi_test_init()` from `tests/helpers/common.bash` in tests.

</important>

<important if="you are editing a config file that lives in the home directory (e.g., ~/.tmux.conf, ~/.config/...)">

Edit the **source** in `home/` (e.g., `home/dot_tmux.conf`), not the live file in `~/`. Single source of truth, no drift. Run `chezmoi managed | grep <name>` to check if a file is tracked.

</important>

<important if="you edited a managed file and expect the change to take effect, or you ran chezmoi and got surprising results">

**chezmoi reads its own clone, NOT this working checkout.** There are THREE copies of every managed file:

1. **This repo checkout** (`~/Projects/my-mac-setup/home/...`) — where you edit and commit. `chezmoi` does **not** read it.
2. **chezmoi source** (`~/.local/share/chezmoi/home/...`) — a **separate git clone** of the same repo. Every `chezmoi` command (`source-path`, `managed`, `diff`, `apply`) reads this, not copy 1.
3. **Live file** (`~/.config/...`, `~/.claude/...`) — what tools actually run. `chezmoi apply` deploys it from copy 2.

Consequence: an edit in this checkout is **commit-ready but NOT live** — it hasn't reached copy 2 or 3. The path to live is commit here → sync into copy 2 (`git pull` there) → `chezmoi apply` (forbidden on host per the rule above, so the user runs it). Never assume your edit took effect in-session. Verify a file's chezmoi source with `chezmoi source-path ~/<live-path>` — it returns a path under `~/.local/share/chezmoi`, confirming the split.

</important>

<important if="you are adding a new tool, app, config file, or directory">

Where new things go:

| Adding | Destination |
|---|---|
| Cross-platform CLI tool | `home/private_dot_config/brewfiles/Brewfile.tmpl` |
| macOS-only cask/app | `home/private_dot_config/brewfiles/Brewfile.macos.tmpl` |
| Config file from `~/` | `home/` via `chezmoi add` |
| External repo/archive (skills) | `home/.chezmoiexternal.toml` |

Adding a managed config, step by step:

1. Check `home/.chezmoiexternal.toml` — skills and configs managed there (e.g., `linear-cli`, `improve-claude-md`) must NOT be duplicated in `home/`, or chezmoi reports "inconsistent state".
2. `chezmoi add ~/.config/tool` — creates the source file in `home/`.
3. Add a `.tmpl` suffix if the file needs OS branching or secrets; OS-specific files also need a rule in `home/.chezmoiignore`.
4. Coverage passes the test-oracle gate first: state the oracle line (consumer, observable failure, oracle independent of this change) — when it cannot be completed, zero new tests is the correct outcome. When it can, extend the narrowest test that proves deployment behavior; use `tests/bashunit/smoke_test.sh` only for cross-component coverage.
5. Verify: `make test-local` (diff only), then `make test-ubuntu`.

`modify_` scripts (e.g., `modify_dot_claude.json`) read the existing file from stdin and output a modified version — don't treat them as regular templates.

</important>

<important if="you are adding or changing agent skills">

- `home/private_dot_config/agent-skills/manifest` is the source of truth for selected upstream skills. Use `~/.local/bin/skills {add|remove|update|sync}` to manage the live global installation; `sync` reports drift but never removes it.
- `home/private_dot_agents/skills/` is chezmoi's canonical storage for repository-owned model-invocable skills. The Skills CLI owns separate children in `~/.agents/skills` and records their ownership in its global lock; do not let either owner claim the same effective skill name.
- `eli5` and `open-questions` are explicit-only Claude/Pi adapters with OpenCode command adapters. Client plugins retain non-skill functionality only. Restart Claude Code, OpenCode, and Pi after deployment or discovery changes.

</important>

<important if="you are adding or changing an explicit-only workflow">

An explicit-only workflow interrupts the current task and must run only after a direct user request. Keep one canonical description and body in `home/.chezmoitemplates/explicit-only-<name>-description.txt` and `home/.chezmoitemplates/explicit-only-<name>-body.md`.

Package the canonical content through three thin adapters:

- Claude Code: `home/private_dot_claude/skills/<name>/SKILL.md.tmpl`, with `disable-model-invocation: true`. Pi reads this deployed skill through its existing `~/.claude/skills` source and needs no separate adapter.
- Pi: `home/dot_pi/agent/skills/symlink_<name>.tmpl`, targeting the deployed Claude skill directory so Pi keeps the same explicit-only metadata.
- OpenCode: `home/private_dot_config/opencode/commands/<name>.md.tmpl`, which exposes a manual command. Never add the workflow under `home/private_dot_config/opencode/skills/`.

Use raw `include` with the explicit `.chezmoitemplates/<file>` path so literal Markdown and Go-template syntax remain data. Do not use `includeTemplate`, which executes the included content. Treat `$ARGUMENTS`, `$<digits>`, and unquoted `@path` as reserved OpenCode command syntax; a workflow that must preserve these sequences literally needs client-specific content instead.

Keep `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1` in `home/dot_zshenv.tmpl` so OpenCode cannot discover the Claude-only adapters. Do not set `OPENCODE_DISABLE_EXTERNAL_SKILLS`; OpenCode must discover shared `~/.agents/skills` natively. After deployment, restart each client from the managed zsh environment before checking discovery. Add the workflow name to the `explicit-only workflows keep manual invocation boundaries` case in `tests/bashunit/smoke_test.sh`, then run `make test-templates` and `make test-ubuntu`.

</important>

<important if="you are working with templates, secrets, or 1Password integration">

- **Never** hardcode secrets — use `onepasswordRead` in templates.
- 1Password calls must be guarded by `lookPath "op"` so CI/Docker environments (without 1Password) still apply. Real pattern from `home/dot_zshenv.tmpl`:

  ```
  {{ if lookPath "op" }}
  export LINEAR_API_KEY="{{ onepasswordRead "op://Private/Linear API Key/credential" "my.1password.com" }}"
  {{- end }}
  ```

- `op` must be absent from `PATH` in test environments, otherwise 1Password templates fail.
- Required env vars in CI: `CHEZMOI_NAME`, `CHEZMOI_EMAIL` (set in the GitHub workflow).

</important>

## Repository issues

Use the `repository-issues` skill and `python3 scripts/issues` for `docs/issues/` lifecycle operations. Create an issue for every unresolved problem.

Costly-to-reverse architecture decisions go to `docs/decisions/` as minimal Architecture Decision Records with `Context`, `Considered options`, and `Decision` sections.

<important if="you are adding, changing, or reviewing tests">

- Read `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md`; it defines semantic regression tests, control fixtures, coverage ownership, and honest verification.
- Assert command status before inspecting output. Pair rejection fixtures with a nearby valid control that reaches the intended success path.
- Search existing coverage first and strengthen its best owner instead of duplicating the assertion. Put new coverage in the narrowest relevant suite; reserve `tests/bashunit/smoke_test.sh` for deployed cross-component behavior.
- Run the smallest canonical `make` target that covers the change instead of reconstructing its component commands.
- Run `make test-suite` for the parallel host-safe files, or `make test-ubuntu` for the full Docker suite including `tests/bashunit/idempotent_test.sh`.
- `tests/bashunit/idempotent_test.sh` guards every real chezmoi command with `MMS_DISPOSABLE_HOME=1`. Direct workstation runs skip those commands; `make test-ubuntu` declares a disposable `$HOME` and runs them.
- `make test-suite` reads the deployed `~/` and applies nothing, so it cannot see an edit under `home/` that has not been applied yet. For a change to a managed file, `make test-ubuntu` is the one that proves it — it applies the checkout first.
- Treat skips, partial runs, and isolated passes as incomplete evidence. If a required suite stalls, record the exact boundary, isolate the case, create a repository issue, and report the suite as incomplete.
- CI runs both ubuntu and macos jobs.
- Use `chezmoi_test_init()` from `tests/helpers/common.bash` instead of raw `chezmoi init`.

</important>
