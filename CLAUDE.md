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

- `browsers/` contains browser extension configs — not managed by chezmoi
- New features should have a smoke test in `tests/smoke.bats` (bats-core syntax)
- `.chezmoiroot` = `home` — chezmoi source is `home/`, not repo root
- `modify_` scripts (e.g., `modify_dot_claude.json`) read existing file from stdin, output modified version — don't treat them as regular templates
- Template vars (`.name`, `.email`, `.is_darwin`, `.is_linux`) defined in `home/.chezmoi.yaml.tmpl` via env vars or interactive prompt
- `CHEZMOI_NAME` / `CHEZMOI_EMAIL` env vars required in CI (set in workflow)
- `op` must be absent from PATH in test environments, otherwise 1Password templates fail

## Commands

```bash
make test-ubuntu    # full test in Docker
make test-local     # chezmoi diff (dry-run, no changes)
make lint           # shellcheck
make clean          # remove Docker resources
```
