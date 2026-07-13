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

<important if="you need to run commands to build, test, lint, or run scripts">

| Command | What it does |
|---|---|
| `make test-ubuntu` | Full test in Docker |
| `make test-docker` | Build + run full Docker test suite |
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

<important if="you are adding a new file or directory to the chezmoi source tree">

- Check `home/.chezmoiexternal.toml` first — skills and configs managed there (e.g., `linear-cli`, `improve-claude-md`) must NOT be duplicated in `home/`, or chezmoi reports "inconsistent state".
- `chezmoi add ~/.config/tool` creates the source file in `home/`. Use a `.tmpl` suffix if the file needs OS branching or secrets.
- `modify_` scripts (e.g., `modify_dot_claude.json`) read the existing file from stdin and output a modified version — don't treat them as regular templates.

</important>

<important if="you are adding or removing a CLI tool, app, or cask">

- Cross-platform CLIs go in `home/private_dot_config/brewfiles/Brewfile`.
- macOS-only casks/apps go in `home/private_dot_config/brewfiles/Brewfile.macos`.

</important>

<important if="you are working with templates, secrets, or 1Password integration">

- **Never** hardcode secrets — use `onepasswordRead` in templates.
- 1Password calls must be guarded by `lookPath "op"` so CI/Docker environments (without 1Password) still apply.
- `op` must be absent from `PATH` in test environments, otherwise 1Password templates fail.
- Required env vars in CI: `CHEZMOI_NAME`, `CHEZMOI_EMAIL` (set in the GitHub workflow).

</important>

<important if="you are adding a new feature, script, or config that should be tested">

- Add a smoke test in `tests/smoke.bats` (bats-core syntax).
- Run locally with `bats tests/smoke.bats`, or `make test-ubuntu` for the full Docker suite.
- CI runs both ubuntu and macos jobs.
- Use `chezmoi_test_init()` from `tests/helpers/common.bash` instead of raw `chezmoi init`.

</important>
