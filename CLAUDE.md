# my-mac-setup

Reproducible dev environment for macOS (primary) and Linux (CI/Docker).
One repo → `chezmoi apply` → fully configured machine with all tools, configs, and secrets.

## What Claude needs to know

- **Never** run `chezmoi apply` in this repo — use `make test-local` (diff only) or `make test-ubuntu` (Docker)
- **Never** hardcode secrets — always use `onepasswordRead` in templates
- **Adding a CLI tool**: add to `home/private_dot_config/brewfiles/Brewfile` (cross-platform) or `Brewfile.macos` (macOS-only casks/apps)
- **Adding a config**: `chezmoi add ~/.config/tool` creates it in `home/`; use `.tmpl` suffix if it needs OS branching or secrets
- **Secrets**: injected via 1Password (`onepasswordRead` in templates). Guarded by `lookPath "op"` — CI/Docker environments work without 1Password
- **Testing changes**: `make test-ubuntu` (Docker) or `bats tests/smoke.bats` locally. CI runs both ubuntu + macos

## Gotchas

- **Check `.chezmoiexternal.toml` before adding files** — skills and configs managed there (e.g., `linear-cli`, `react-best-practices`) must NOT be duplicated in `home/`. Causes "inconsistent state" errors
- `home/.chezmoiscripts/` — run scripts executed by chezmoi during apply (install Homebrew, etc.)
- `home/.chezmoiexternal.toml` — external archives/repos pulled by chezmoi (e.g., bats-libs)
- `home/.chezmoiignore` — OS-conditional ignore rules (darwin-only vs linux-only files)
- `browsers/` contains browser extension configs — not managed by chezmoi
- New features should have a smoke test in `tests/smoke.bats` (bats-core syntax)
- `.chezmoiroot` = `home` — chezmoi source is `home/`, not repo root
- `modify_` scripts (e.g., `modify_dot_claude.json`) read existing file from stdin, output modified version — don't treat them as regular templates
- Template vars (`.name`, `.email`, `.is_darwin`, `.is_linux`) defined in `home/.chezmoi.yaml.tmpl` via env vars or interactive prompt
- `CHEZMOI_NAME` / `CHEZMOI_EMAIL` env vars required in CI (set in workflow)
- `op` must be absent from PATH in test environments, otherwise 1Password templates fail
- **Never** run `chezmoi init` without `--config /tmp/chezmoi-test.yaml --config-path /tmp/chezmoi-test.yaml` outside of Docker/CI — it overwrites the host's real config. Use `chezmoi_test_init()` from `tests/helpers/common.bash` in tests

## Commands

```bash
make test-ubuntu    # full test in Docker
make test-docker    # build + run full Docker test suite
make test-templates # template tests only (fast, no apply)
make test-local     # chezmoi diff (dry-run, no changes)
make lint           # shellcheck
make shell-ubuntu   # interactive shell in Ubuntu container
make build-docker   # build Docker image only
make clean          # remove Docker resources
bats tests/smoke.bats  # run a single test file
```
