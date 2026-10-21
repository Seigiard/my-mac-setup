---
name: agent-reports
description: Private HTML reports on Cloudflare R2 for humans and agents. Use to publish a local report folder and get a browser link, to fetch a report from an r2://agent-reports/... URI or a reports.1218217.xyz link, or to share a report as a time-limited zip link.
---

# Agent reports

Reports live in the private R2 bucket `agent-reports` for 28 days. Humans open the `viewer_url` after a Cloudflare Access login. Agents work through the CLI from <https://github.com/Seigiard/agent-reports>.

When `publish-report` is not on `PATH`, install the CLI:

```bash
uv tool install git+ssh://git@github.com/Seigiard/agent-reports.git#subdirectory=cli
```

## Publish

1. Write the report as a folder with `index.html` at its root; a single built page is a folder holding it as `index.html`. Reference assets with relative paths (`assets/chart.png`). Keep secrets, tokens and personal data out of the report.
2. Run `publish-report <folder> --project <repo-or-topic> --json`. `--dry-run` validates the folder without credentials.
3. Give the user `viewer_url`. Give another agent `r2_uri` or `get_command`.

Done when the command exits 0 and the user has the `viewer_url`.

## Fetch

```bash
get-r2-report <r2_uri> <new-folder>      # whole folder, assets and manifest.json included
get-r2-report <r2_uri> --stdout          # entry HTML only, for reading
```

A link `https://reports.1218217.xyz/reports/<project>/<run-id>/...` maps to `r2://agent-reports/reports/<project>/<run-id>/`. Convert it and fetch with `get-r2-report`: the browser link sits behind Access, and one HTML file arrives without its assets.

## Share outside

Only when the user asks to share with someone who has no credentials:

```bash
share-r2-report <r2_uri> --ttl 24h
```

The output is a presigned `report.zip` URL plus `curl` and `unzip` commands. The URL is a bearer secret: hand it only to the named recipient, and keep it out of commits, issues, PRs and shared logs. Pick the shortest TTL that works; the maximum is 7d.

## Errors

- `missing environment variables`: the `AGENT_REPORTS_*` keys come from the machine secrets in `~/.zshenv`. Tell the user to run `chezmoi apply` and open a new shell; the user handles keys.
- `credentials rejected`: the key is wrong, revoked, or scoped to another bucket.
- `not found (expired or never published)`: the report is older than 28 days, or the URI is wrong.
