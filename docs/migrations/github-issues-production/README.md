# Former local issue IDs

Until 2026-09-13 this repository tracked work as Markdown records under
`docs/issues/`, each named by a local ID such as `2026-08-18-014`. GitHub Issues
in `Seigiard/my-mac-setup` replaced that tracker (see
[ADR-0013](../../decisions/0013-use-github-issues-as-the-repository-work-tracker.md)).
The local records are gone; this directory is how a former ID is still resolved.

## Resolving an ID

Look the ID up in [`legacy-id-resolution-manifest.json`](legacy-id-resolution-manifest.json),
which covers all 59 former records and is the only place the ID-to-issue mapping
survives:

- **37 active records** carry a `github_issue_url`. Open it.
- **22 terminal records** (`done` or `wontfix`) were never imported and carry a
  `source_path` instead. That path is complete, so read the record at the
  immutable source commit `27f33a235548f19422b94565f6a14613219b5d5b`:

  ```sh
  git show 27f33a235548f19422b94565f6a14613219b5d5b:<source_path>
  ```

  Their durable knowledge was compounded into `docs/solutions/` and the decision
  records before removal; the source record is the historical original, not live
  work.

## Issues that moved after the cutover

Four migrated issues were transferred to `Seigiard/herdr-command-palette` on
2026-09-16, when that plugin became its own repository
([ADR-0015](../../decisions/0015-extract-herdr-command-palette.md)). Their bodies,
markers, and provenance survived the move, and the URLs recorded in the manifest
still redirect, but the manifest text itself was left at the original numbers:

| Legacy ID | Recorded URL | Now lives at |
|---|---|---|
| `2026-08-18-014` | `my-mac-setup#227` | [`herdr-command-palette#3`](https://github.com/Seigiard/herdr-command-palette/issues/3) |
| `2026-08-18-015` | `my-mac-setup#228` | [`herdr-command-palette#1`](https://github.com/Seigiard/herdr-command-palette/issues/1) |
| `2026-08-18-024` | `my-mac-setup#234` | [`herdr-command-palette#4`](https://github.com/Seigiard/herdr-command-palette/issues/4) |
| `2026-09-02-013` | `my-mac-setup#244` | [`herdr-command-palette#2`](https://github.com/Seigiard/herdr-command-palette/issues/2) |

## What the manifest holds

[`manifest.json`](manifest.json) is the reviewed migration manifest, bound to the
same source commit. It records every former record's source identity and
SHA-256, and for the 37 imported records the title, body, and labels the import
planned to create. It holds no issue numbers or URLs — resolve those through
`legacy-id-resolution-manifest.json` above. The manifest's SHA-256 is
`4956970874c38d81904f390ec8e0eb70380555d0aae3032489bd61ad1805ceb3`.

Each migrated issue body ends with a hidden marker,
`<!-- my-mac-setup-issue-migration:<legacy-id> -->`, so a GitHub issue can be
traced back to its former ID. Most also carry a visible `Legacy source:` footer,
though a body rewritten since the cutover may state its origin differently.

## Scope

These files are provenance, not a tracker. GitHub Issues is the sole authority
for repository work — see [`docs/agents/issue-tracker.md`](../../agents/issue-tracker.md).

The temporary importer and verifier that performed the migration, their run
state, and the pilot and production import evidence were deleted on 2026-09-18,
after the four-day stabilization window set by ADR-0013 closed on 2026-09-17.
Stabilization verification was completed first and is recorded in the commit
that removed them. All of it remains in Git history at
`a4fc4075e21fb9a17282fdf8247d4dbf7684a80e` and earlier.
