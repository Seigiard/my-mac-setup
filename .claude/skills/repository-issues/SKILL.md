---
name: repository-issues
description: Manage repository issues in docs/issues with scripts/issues. Use for issue queries, lifecycle changes, validation, or unresolved work.
---

# Repository Issues

Use `python3 scripts/issues` from the repository root for all issue lifecycle operations. Treat `docs/issues/` as structured records, not free-form Markdown.

## Schema

Each issue is `docs/issues/YYYY-MM-DD-NNN-slug.md`. Its frontmatter has these required fields:

| Field | Values or format |
|---|---|
| `title` | Concise, stable label for the issue |
| `short_description` | One self-contained sentence that explains the issue beyond the title |
| `type` | `bug`, `follow-up`, `idea`, or `chore` |
| `category` | A category in the table below |
| `tags` | JSON array of unique kebab-case tags |
| `date` | `YYYY-MM-DD`, matching the filename date |
| `status` | `open`, `in-progress`, `done`, or `wontfix` |
| `priority` | `critical`, `high`, `medium`, or `low` |

`parent-plan` is optional. Terminal issues also require `closed` and a `## Resolution` section. Active issues require `## Why this exists`, `## Scope`, and `## Open decisions`.

### Writing titles and short descriptions

Keep `title` concise and stable so lists remain scannable. Use `short_description` for the current, information-dense summary of the issue.

A good `short_description`:

- is one self-contained sentence;
- adds concrete mechanism, impact, evidence, constraint, or intended outcome beyond the title;
- keeps useful commands, paths, measurements, and known blockers when they explain why the issue matters;
- describes the current understanding, not only the state when the issue was created;
- does not repeat or lightly paraphrase the title.

When investigation changes the diagnosis, impact, scope, blocker, or intended outcome, update `short_description` in the same lifecycle operation. Before finishing `start`, `edit`, `close`, or `wontfix` work, compare the description with the current issue body and revise stale wording through `scripts/issues edit`.

Example:

```yaml
title: "macOS suite misses wall-time gate"
short_description: "The parallel post-apply suite reaches 67% of the serial baseline against a 60% target; stable runs show a deferred optimization gap rather than a regression."
```

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

List active issues and apply structured filters with `list`:

```sh
python3 scripts/issues validate
python3 scripts/issues list --status open --priority high
python3 scripts/issues search "search text" --json
python3 scripts/issues show 2026-08-21-001 --json
```

The default list includes `open` and `in-progress`, groups readable output by category, and orders each category by priority and canonical ID. Repeating `--status`, `--category`, `--priority`, or `--type` matches any supplied value within that field. Repeating `--tag` requires every supplied tag. Different fields combine with AND. `search` applies the same filters and searches titles, descriptions, and bodies.

`list --json` returns `{"issues":[...]}`. Each item has `category`, `id`, `priority`, `short_description`, `status`, and `title`. `show ID --json` returns `body`, `id`, `metadata`, and the repository-relative `path`. JSON keys and result ordering are stable for an unchanged corpus.

Create and change lifecycle state through the CLI:

```sh
python3 scripts/issues create --title "Short title" --short-description "One sentence." --type bug --category testing-ci --priority high --tag regression
python3 scripts/issues start 2026-08-21-001
python3 scripts/issues edit 2026-08-21-001 --priority medium
python3 scripts/issues close 2026-08-21-001 --resolution "Implemented and verified."
python3 scripts/issues wontfix 2026-08-21-001 --rationale "The cost exceeds the benefit."
```

On success, `create` prints the repository-relative issue path. `start`, `edit`, `close`, and `wontfix` print the canonical ID, path, and resulting status. Run `validate` before treating a mutation as complete.

Success exits `0`. Strict validation violations exit `1`. CLI contract errors exit `2`, write `CODE: detail` to stderr, and leave issue files unchanged. Argument parser errors also exit `2` with argparse usage text.

Use `validate` to check the complete current corpus without rewriting records.

## Escalation

Create a repository issue for every unresolved problem. Use the CLI instead of manually changing lifecycle fields or filenames.
