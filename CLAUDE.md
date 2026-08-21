# my-mac-setup

Reproducible dev environment for macOS (primary) and Linux (CI/Docker), managed by chezmoi. One repo → `chezmoi apply` → fully configured machine with tools, configs, and secrets.

## Project map

- `home/` — chezmoi source tree (`.chezmoiroot` = `home`); files map to `~/`
- `home/.chezmoiscripts/` — run scripts executed by chezmoi during apply (install Homebrew, etc.)
- `home/.chezmoiexternal.toml` — external archives/repos pulled by chezmoi (e.g., bats-libs, skills)
- `home/.chezmoiignore` — OS-conditional ignore rules (darwin-only vs linux-only files)
- `home/.chezmoi.yaml.tmpl` — template vars (`.name`, `.email`, `.is_darwin`, `.is_linux`)
- `home/private_dot_config/brewfiles/` — `Brewfile` (cross-platform) and `Brewfile.macos` (macOS-only)
- `tests/` — bats-core smoke tests; `tests/helpers/common.bash` has shared helpers
- `docker/` — Dockerfile and scripts for `make test-ubuntu`
- `browsers/` — browser extension configs (NOT managed by chezmoi)
- `configs/`, `docs/`, `macos-settings.md` — supplementary material

Reference docs (read on demand):

- `docs/solutions/` — documented learnings from past work (architecture and design patterns), organized by category with YAML frontmatter (`module`, `tags`, `problem_type`); relevant when implementing or debugging in areas they cover
- `CONCEPTS.md` — shared domain vocabulary (entities, named processes, status concepts); relevant when orienting in the se-pipeline domain or naming things consistently
- `docs/se-pipeline.md` — se-pipeline (Smithers) runbook: durable verify-doc → work → verify-code runs
- `docs/agent-setup-inventory.md` — curated plugins/skills/agents for manual reinstall across Claude Code, OpenCode, Pi
- `docs/external-agent-cli-flags.md` — headless/one-shot invocation flags for external coding-agent CLIs

<important if="you need to run commands to build, test, lint, or run scripts">

| Command | What it does |
|---|---|
| `make test-ubuntu` | Full test in Docker |
| `make test-docker` | Build + run full Docker test suite |
| `make test-suite` | Post-apply suite in parallel, host-safe files only (excludes `tests/idempotent.bats`, which applies to the real `$HOME`). Asserts against the **already-applied** `~/`, not this checkout — an unapplied edit under `home/` is not covered and still goes green |
| `make test-templates` | Template tests only (fast, no apply) |
| `make test-local` | `chezmoi diff` (dry-run, no changes) |
| `make lint` | shellcheck |
| `make shell-ubuntu` | Interactive shell in Ubuntu container |
| `make build-docker` | Build Docker image only |
| `make clean` | Remove Docker resources |
| `bats tests/smoke.bats` | Run a single test file |

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
| External repo/archive (skills, bats-libs) | `home/.chezmoiexternal.toml` |

Adding a managed config, step by step:

1. Check `home/.chezmoiexternal.toml` — skills and configs managed there (e.g., `linear-cli`, `improve-claude-md`) must NOT be duplicated in `home/`, or chezmoi reports "inconsistent state".
2. `chezmoi add ~/.config/tool` — creates the source file in `home/`.
3. Add a `.tmpl` suffix if the file needs OS branching or secrets; OS-specific files also need a rule in `home/.chezmoiignore`.
4. Add a smoke test in `tests/smoke.bats`.
5. Verify: `make test-local` (diff only), then `make test-ubuntu`.

`modify_` scripts (e.g., `modify_dot_claude.json`) read the existing file from stdin and output a modified version — don't treat them as regular templates.

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

<important if="you are adding a new feature, script, or config that should be tested">

- Add a smoke test in `tests/smoke.bats` (bats-core syntax).
- Run locally with `make test-suite` (parallel, host-safe files), or `make test-ubuntu` for the full Docker suite including `tests/idempotent.bats`.
- `make test-suite` reads the deployed `~/` and applies nothing, so it cannot see an edit under `home/` that has not been applied yet. For a change to a managed file, `make test-ubuntu` is the one that proves it — it applies the checkout first.
- CI runs both ubuntu and macos jobs.
- Use `chezmoi_test_init()` from `tests/helpers/common.bash` instead of raw `chezmoi init`.

</important>
