---
name: repository-issues
description: Manage repository issues in docs/issues with scripts/issues. Use when creating, searching, validating, editing, closing, or migrating a repository issue, or when an unresolved problem needs tracking.
---

# Repository Issues

Use `python3 scripts/issues` from the repository root for all issue lifecycle operations. Treat `docs/issues/` as structured records, not free-form Markdown.

## Schema

Each issue is `docs/issues/YYYY-MM-DD-NNN-slug.md`. Its frontmatter has these required fields:

| Field | Values or format |
|---|---|
| `title` | Non-empty text |
| `short_description` | Non-empty text |
| `type` | `bug`, `follow-up`, `idea`, or `chore` |
| `category` | A category in the table below |
| `tags` | JSON array of unique kebab-case tags |
| `date` | `YYYY-MM-DD`, matching the filename date |
| `status` | `open`, `in-progress`, `done`, or `wontfix` |
| `priority` | `critical`, `high`, `medium`, or `low` |

`parent-plan` is optional. Terminal issues also require `closed` and a `## Resolution` section. Active issues require `## Why this exists`, `## Scope`, and `## Open decisions`.

## Classification

| Category | Use for |
|---|---|
| `testing-ci` | Tests, continuous integration, and verification |
| `se-pipeline` | Software-engineering pipeline behavior |
| `herdr` | Herdr panes, events, and task coordination |
| `command-palette` | Command palette behavior |
| `agent-platform` | Agent clients, skills, and integrations |
| `dotfiles` | Managed machine configuration |
| `repository-maintenance` | Repository structure and maintenance |

Set `critical` for urgent breakage or data loss. Set `high` for important near-term work. Set `medium` for planned work. Set `low` for useful but deferrable work.

## Commands

Read first:

```sh
python3 scripts/issues validate --compatibility
python3 scripts/issues list --status open --priority high
python3 scripts/issues show 2026-08-21-001 --json
```

Create and change lifecycle state through the CLI:

```sh
python3 scripts/issues create --title "Short title" --short-description "One sentence." --type bug --category testing-ci --priority high --tag regression
python3 scripts/issues start 2026-08-21-001
python3 scripts/issues edit 2026-08-21-001 --priority medium
python3 scripts/issues close 2026-08-21-001 --resolution "Implemented and verified."
python3 scripts/issues wontfix 2026-08-21-001 --rationale "The cost exceeds the benefit."
```

`list` accepts repeated `--status`, `--category`, `--priority`, `--type`, and `--tag` filters. Repeated statuses and priorities match any supplied value. Repeated tags must all match. Use `--json` for machine-readable `list` and `show` output.

Use `validate` without `--compatibility` after the corpus is migrated. The compatibility mode reports legacy missing fields but does not rewrite records.

## Migration Approval

Use `migrate` only after a maintainer approves the reviewed migration manifest. Before approval, provide the exact manifest path, its SHA-256, and the committed source revision. Do not apply, regenerate, or alter the manifest while awaiting approval. After approval, run the approved migration and `python3 scripts/issues validate`.

## Escalation

Create a repository issue for every unresolved problem. Use the CLI instead of manually changing lifecycle fields or filenames.
