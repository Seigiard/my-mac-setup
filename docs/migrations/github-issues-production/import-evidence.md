# GitHub Issues production import evidence

Issue: [#208](https://github.com/Seigiard/my-mac-setup/issues/208)

Target repository: `Seigiard/my-mac-setup`

Approved manifest: `docs/migrations/github-issues-production/manifest.json`

Manifest SHA-256: `4956970874c38d81904f390ec8e0eb70380555d0aae3032489bd61ad1805ceb3`

Source commit: `27f33a235548f19422b94565f6a14613219b5d5b`

## Oracle

The consumer is the temporary production importer and verifier. A failure is any
missing, duplicated, drifted, or partially repaired GitHub issue among the 37
approved active targets, any unexpected mutation on the 22 terminal
provenance-only records, or any no-op rerun that performs another mutation.

The narrow oracle is the importer state plus a complete paginated GitHub export
verified against the reviewed manifest by `scripts/verify_github_issue_migration.py`.
The verifier checks target identity, body, title, marker, labels, assignees,
state, repaired links, label definitions, duplicate markers, and unmarked
bootstrap issue allowance.

## Maintainer authorization

The production import was explicitly authorized in-session before the first
mutating command. At authorization time, the target repository contained seven
unmarked bootstrap issues (`#204` through `#210`) and no migration-marked issues.

## Source freeze

The local tracker remained present during the import. Before and after final
verification, the 59 local source records matched the manifest-recorded SHA-256
values:

```text
source_freeze_matches_manifest=True records=59 problems=0
```

No `docs/issues/` source record was changed by this ticket.

## Import result

Command:

```sh
python3 scripts/github_issue_migration.py apply \
  --manifest docs/migrations/github-issues-production/manifest.json \
  --state docs/migrations/github-issues-production/import-state.json \
  --repo Seigiard/my-mac-setup
```

Result:

```json
{"bodies_repaired":2,"issues_closed":0,"issues_created":37,"issues_recovered":0,"labels_created":1,"mutations":40,"repository":"Seigiard/my-mac-setup","result":"complete"}
```

The importer created exactly 37 manifest-owned issues in deterministic source
order. Their production issue numbers are `#214` through `#250`, persisted in
`docs/migrations/github-issues-production/import-state.json`. The 22 terminal
source records remained provenance-only and were not created as GitHub issues.

## Parity verification

Command:

```sh
python3 scripts/verify_github_issue_migration.py verify \
  --manifest docs/migrations/github-issues-production/manifest.json \
  --state docs/migrations/github-issues-production/import-state.json \
  --repo Seigiard/my-mac-setup \
  --output docs/migrations/github-issues-production/target-export.json
```

Result:

```json
{"duplicate_issue_count":0,"duplicate_marker_count":0,"issue_count":37,"manifest_sha256":"4956970874c38d81904f390ec8e0eb70380555d0aae3032489bd61ad1805ceb3","repaired_link_count":5,"repository":"Seigiard/my-mac-setup","schema_version":1,"unmarked_issue_count":7,"verified":true}
```

The verified export contains 37 migration-owned issues, five repaired legacy
links, and the seven allowed unmarked bootstrap issues.

Label distribution in the verified export:

| Label | Count |
|---|---:|
| `bug` | 4 |
| `enhancement` | 33 |
| `ready-for-agent` | 34 |
| `ready-for-human` | 3 |

## No-op rerun

Command:

```sh
python3 scripts/github_issue_migration.py apply \
  --manifest docs/migrations/github-issues-production/manifest.json \
  --state docs/migrations/github-issues-production/import-state.json \
  --repo Seigiard/my-mac-setup
```

Result:

```json
{"bodies_repaired":0,"issues_closed":0,"issues_created":0,"issues_recovered":0,"labels_created":0,"mutations":0,"repository":"Seigiard/my-mac-setup","result":"noop"}
```

The post-rerun verification wrote
`docs/migrations/github-issues-production/target-export-after-noop.json`, and
`cmp docs/migrations/github-issues-production/target-export.json docs/migrations/github-issues-production/target-export-after-noop.json`
returned `0`.

## Local verification

```sh
python3 -m unittest tests.test_github_issue_migration
# Ran 4 tests in 0.739s - OK

make test-python
# Ran 34 tests in 9.778s - OK
```

## Durable artifacts and legacy-ID resolution

Resolve a former local ID through `legacy-id-resolution-manifest.json`. Its 37
active entries contain production GitHub issue URLs. Its 22 terminal entries
contain source paths that combine with the manifest's immutable `source_commit`
to locate the exact record in GitHub source history.

- `docs/migrations/github-issues-production/legacy-id-resolution-manifest.json` — permanent resolution for all 59 former local IDs.
- `docs/migrations/github-issues-production/import-state.json` — source ID to production issue identity mapping.
- `docs/migrations/github-issues-production/target-export.json` — verified paginated export after import.
- `docs/migrations/github-issues-production/target-export-after-noop.json` — verified paginated export after the no-op rerun.
- `docs/migrations/github-issues-production/import-run-log.txt` — import terminal output and status.
- `docs/migrations/github-issues-production/verify-run-log.txt` — first parity verification terminal output and status.
- `docs/migrations/github-issues-production/noop-run-log.txt` — no-op rerun terminal output and status.
- `docs/migrations/github-issues-production/verify-after-noop-run-log.txt` — post-rerun parity verification and export comparison.
- `docs/migrations/github-issues-production/source-freeze-log.txt` — final local source-record hash check and status.
