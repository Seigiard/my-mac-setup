---
title: Use GitHub Issues as the repository work tracker
status: accepted
date: 2026-09-13
supersedes: ["ADR-0007"]
---

# ADR-0013: Use GitHub Issues as the repository work tracker

## Context

ADR-0007 made validated Markdown records under `docs/issues/` authoritative and
introduced a repository-owned CLI, schema, tests, CI gates, and Docker wiring.
In use, concurrent issue creation still causes numbering conflicts, Markdown
files are inconvenient to browse, and maintaining a complete tracker subsystem
adds more repository complexity than its local validation and offline operation
are worth. The repository already uses GitHub, and network and GitHub
authentication are acceptable dependencies for both the maintainer and agents.

The capability and migration trade-offs are documented in
`docs/plans/2026-09-13-github-issues-migration-research.md`.

## Considered options

- Keep the validated Markdown tracker.
- Mirror or dual-write issues between Markdown and GitHub.
- Import every active and terminal record into GitHub Issues.
- Import active work into GitHub and retain Markdown as a live local archive.
- Import active work into GitHub, retain provenance through Git, Compound
  learnings, and a migration manifest, then remove the local tracker.

## Decision

GitHub Issues will become the only authoritative repository work tracker. Agents
and humans will use the `gh` CLI directly; the repository will not replace the
local issue CLI with another permanent wrapper.

The tracker follows the defaults configured by `setup-matt-pocock-skills`:

- every triaged issue has one category role, `bug` or `enhancement`;
- every triaged issue has one state role: `needs-triage`, `needs-info`,
  `ready-for-agent`, `ready-for-human`, or `wontfix`;
- assignment claims work in progress;
- explicit blocking edges and parent-child relationships use GitHub's native
  issue dependencies and sub-issues, with the documented text fallback when a
  native feature is unavailable; and
- pull requests are not a triage request surface.

The repository will not recreate its former schema as `type:*`, `area:*`,
`priority:*`, free-form tag, or status labels. Existing unrelated GitHub default
labels may remain, but they do not form a second workflow vocabulary. External
issues are allowed and enter through `needs-triage`; the existing ownership gate
still decides whether proposed work belongs in this repository.

Migration imports the 37 active records and does not import the 22 `done` or
`wontfix` records. Each imported issue keeps its title, starts its body with the
former short description, retains the useful Markdown sections, links any
`parent-plan`, and ends with a concise legacy-ID provenance footer. Existing
textual references become GitHub links but are not promoted to blocking edges
without explicit blocking semantics.

A reviewed manifest binds all 59 former IDs and paths to the source commit and
records target URLs for imported issues. After a private scratch-repository
pilot, production migration uses a short local write freeze, restart-safe
idempotent import, a second link-repair pass, parity verification, and one source-
of-truth switch. The temporary importer remains available for a seven-day
stabilization period, during which rerunning it must be a no-op, and is then
removed. Permanent mirroring or dual-write is forbidden.

At cutover, all files under `docs/issues/`, `scripts/issues`, tracker-specific
tests and CI/Docker integration are removed. Durable current references are
rewritten to GitHub issues. Dated historical artifacts remain unchanged and
resolve former IDs through the manifest and source commit. The current
`Seigiard` GitHub identity performs migrations and ordinary agent mutations; a
separate bot or GitHub App is not introduced.

## Consequences

The backlog gains GitHub's rendered interface, comments, notifications, native
relations, and conflict-free issue numbering while the repository sheds a custom
schema, CLI, and their verification surface. The workflow aligns directly with
`to-tickets`, `triage`, `wayfinder`, and the other configured engineering skills.

Issue operations now depend on GitHub availability, network access, credentials,
permissions, and API behavior. Imported issues receive new GitHub numbers,
authorship, timestamps, and timelines; the migration manifest, source commit,
Git history, and existing Compound documents preserve provenance rather than
pretending the import is lossless. A pilot failure blocks production import and
must be fixed and rerun. This decision is reconsidered only if GitHub has a
fundamental limitation whose workaround would require rebuilding a substantial
custom tracker layer.
