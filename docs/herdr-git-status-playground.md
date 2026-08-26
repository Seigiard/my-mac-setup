# Herdr Git status playground runbook

A disposable comparison rig for four Herdr Git/pull-request status plugins
(`ez-corp.git-status`, `git-detail`, `gitlab-ci-status`,
`jmarbutt.spaces-pr-status`), each run alone against the same local Git and
GitHub pull-request fixture catalog. The goal of a run is one attributed
inventory — evidence for a later sidebar-design decision, never a winner.

The controller is `home/dot_local/bin/executable_herdr-git-status-playground`,
deployed by chezmoi to `~/.local/bin/herdr-git-status-playground`. It never
mutates the live Herdr profile, and standard automated tests never contact
GitHub or a real Herdr install (they run against stateful stubs). One real,
authenticated macOS trial is the only place this playground talks to a real
Herdr, Git, and GitHub — and that trial is owned by the operator, not by CI.

## Prerequisites

The command itself needs only Python 3.9+. A **real trial** additionally
needs, on `PATH`:

| Tool | Used by |
|---|---|
| Herdr 0.8.2 (exact version, resolved to an approved absolute path) | every profile |
| Git | fixture construction, all four candidates |
| Cargo | `ez-corp.git-status` build |
| Node.js 20+ | `jmarbutt.spaces-pr-status` build |
| `jq` | `gitlab-ci-status` |
| `gh` (GitHub CLI), authenticated with two **separate** tokens | remote candidates and controller bootstrap |

None of these are added to the managed Homebrew bundle: they are specific to
this disposable trial, not to the base machine contract. `start` preflights
every one of them and fails closed, before any profile or server exists, if
any is missing, at the wrong version, or resolves somewhere other than the
approved path passed via `--approved-herdr`. On failure the reported error
message includes a `toolchain_status` map recording every optional
toolchain's own state (`found` or `missing`), not just the first one checked,
so a single failed preflight tells the operator the complete gap — not one
tool at a time. Remediation is always one of:

- install the missing toolchain **temporarily**, in a scratch location
  removed after the trial (for example a throwaway `rustup`/`npm` prefix), or
- point `PATH` at an already-configured install that lives elsewhere.

Never add a trial-only toolchain to the managed Brewfile.

Herdr identity is checked the same way: the resolved executable's absolute
path, device, and inode are recorded, and any executable reporting a version
other than `0.8.2` — or resolving somewhere other than the approved path —
fails preflight (`HERDR_VERSION_UNAPPROVED` / `HERDR_PATH_CHANGED`).

Two **separate**, least-privilege GitHub credentials are required beyond the
toolchains: a controller-write credential (repository administration:
bootstrap, lease, pending-workflow settlement) and a candidate-read
credential (scoped read-only access for the four candidate profiles). They
are supplied through environment variables
(`HERDR_GIT_STATUS_PLAYGROUND_CONTROLLER_TOKEN`,
`HERDR_GIT_STATUS_PLAYGROUND_CANDIDATE_TOKEN`), never written to a config
file, and never appear together in the same process's environment.

## Fixture ownership

The GitHub side of the catalog lives in one operator-supplied, pre-existing,
otherwise-empty repository — never `my-mac-setup`, and never created or
deleted by the playground. `bootstrap --initialize --fixture-ownership
<path>` performs the one-time atomic claim: it verifies the repository's
canonical host/owner/name and immutable ID, then creates its default branch
with an owned marker file and an inert pinned GitHub Actions workflow
(`permissions: {}`, no secrets, no third-party actions, bounded runtime).
Later runs call plain `bootstrap --fixture-ownership <path>` to converge the
durable pull-request fixtures (`no-pr`, `draft`, `checks-failed`,
`checks-passed`, `merge-conflict`) plus the per-run `checks-pending` fixture,
without recreating or duplicating anything already owned. The
`--fixture-ownership` file records `host`, `owner`, `name`, and
`repository_id` — keep it out of version control; it is a claim record, not
a secret, but it is specific to one operator's fixture repository.

The local side of the catalog (`checkout-clean`, `checkout-dirty`,
`worktree-clean`, `worktree-dirty`, `conflict`, `diverged-stash`, `detached`,
`non-git`) is built fresh, under the run's own disposable directory, on
every `start` — there is nothing to bootstrap for it.

Approved and changes-requested pull-request review states are intentionally
absent from the catalog: a single operator cannot produce a genuine
self-review decision, so those two states are deferred until a second
reviewer identity exists. Do not add them to this playground; a future
review-state pass owns that work.

## Normal use (F1 → F2 → F3)

```
herdr-git-status-playground bootstrap --initialize --fixture-ownership <path>   # once per fixture repository
herdr-git-status-playground bootstrap --fixture-ownership <path>                # idempotent convergence
herdr-git-status-playground start --approved-herdr <path> \
  --fixture-ownership <path> --audit-attestation <path>
herdr-git-status-playground view <run-id>                                       # attach the four-pane comparison viewer
herdr-git-status-playground snapshot <run-id> --profile <name> --fixture <label> \
  --notes "..." --dependency-note "..." --error-link "..." \
  [--applicability applicable|not-applicable|no-visible-signal|discrepancy --applicability-reason "..."] \
  [--screenshot <path>]
herdr-git-status-playground snapshot <run-id> --finalize
herdr-git-status-playground stop <run-id>
```

`--audit-attestation` points at a JSON file recording an operator-approved
audit of each pinned candidate's exact commit and fetched tree — launch is
blocked without one (KTD16). `start` is non-interactive by default: it
returns the run ID once the run reaches `active-ready` and leaves `view` for
later. An interactive terminal instead attaches the viewer immediately.

Candidate names are `ezcorp`, `sfroment`, `krystof`, `jmarbutt`. Fixture
labels are the eight local names above plus the GitHub fixtures prefixed
`gh-` (`gh-no-pr`, `gh-draft`, `gh-checks-failed`, `gh-checks-passed`,
`gh-merge-conflict`) and `gh-checks-pending`. `snapshot --finalize` accepts
the run only once every candidate has exactly one recorded observation for
every fixture, every required field is present, GitHub authority has not
drifted since capture, the four viewer panes are still equal, and every
candidate's live focus matches the run's recorded current fixture.

### Applicability, not ranking

Every snapshot records one of four applicability states:

- `applicable` — the candidate produced ordinary, attributable output.
- `not-applicable` — the candidate has no capability for this fixture family
  at all (for example a pull-request-only candidate against a local-only
  fixture). This is expected, not a defect.
- `no-visible-signal` — the candidate is applicable in principle but showed
  nothing for this fixture; record why in `--applicability-reason`.
- `discrepancy` — the candidate showed something that disagrees with ground
  truth; record the disagreement in the reason.

The inventory never turns any of these into a ranking. It is evidence for
the follow-up sidebar-design brainstorm to weigh, not a verdict this
playground reaches itself.

## Recovery from every non-terminal state

| State | Meaning | Recovery |
|---|---|---|
| `provisioning` | `start` is mid-flight or was interrupted before readiness | `status <run-id>` to inspect; `stop <run-id>` reconciles and tears down whatever was partially launched |
| `active-ready` | Every profile, fixture, and socket is current | Normal `view`/`snapshot`/`stop` |
| `active-degraded` | The run reached `active-ready` once, but a later probe (GitHub authority drift, a dead owned process) failed | `view` still works if you explicitly ask for it; `snapshot` remains diagnostic evidence but cannot satisfy `--finalize`; `stop` is available and is the usual next step |
| `startup-failed-cleaned` | Initial activation failed and automatic cleanup fully succeeded | Nothing to recover — evidence and diagnostics remain readable; start a new run |
| `stopping` | `stop` currently owns the run's mutation lease | Wait, or inspect with `status` from another process; a concurrent `stop` reports `RUN_BUSY` rather than racing |
| `cleanup-incomplete` | `stop` could not prove every owned resource (process, socket, pending GitHub workflow, repository lease, or the live-profile invariant below) was settled | Inspect `teardown.json` and `logs/controller.log` for the exact unresolved code, fix the underlying condition (for example restore a process the operator killed by hand, or confirm no unrelated GitHub activity moved the fixture ref), then run `stop <run-id>` again — repeated `stop` resumes only the still-incomplete phases |
| `stopped` | Every owned local and remote transient is gone, the live-profile invariant matched, and disposable runtime was removed | Terminal; `status` and evidence remain readable indefinitely |

`stop` is always idempotent and safe to repeat. It never signals a process
whose recorded start identity does not match what is actually running, so a
`cleanup-incomplete` run never becomes a reason to reach for `kill` by hand.

## Evidence interpretation

Each run's durable bundle lives under
`${XDG_STATE_HOME:-~/.local/state}/herdr-git-status-playground/runs/<run-id>/`:

- `manifest.json` — run identity, lifecycle state, profile/process ownership,
  and the KTD15 live-profile invariant (`before`/`after`/`match`, see below).
- `ground-truth/` — independently measured Git and GitHub state, captured
  before any candidate can influence what "correct" means for a fixture.
- `observations/` — one timestamped, hashed record per candidate/fixture
  snapshot, plus the no-plugin baseline captured before any candidate
  activated.
- `evidence-index.json` — the flat row list `inventory.md` is projected from;
  each row carries every category below plus its observation ID and evidence
  hashes.
- `inventory.md` — the human worksheet. Every column is an immutable
  controller measurement **except** the three marked `(operator)`
  (readability note, dependency note, error link), which are free text and
  never a ranking. Columns cover: capability family, baseline signal,
  candidate-visible signal, companion surface, ground truth, refresh/
  authority state, terminal dimensions, displaced/duplicated baseline
  signals, applicability, lifecycle state, observation ID, and evidence
  hashes.
- `logs/controller.log` — raw (redacted) diagnostics for troubleshooting a
  run that has not yet reached a fully cleaned terminal state. Removed the
  moment teardown reaches `stopped` (or `startup-failed-cleaned`); it is
  never part of the evidence a successful run retains.
- `teardown.json` — the teardown record: per-candidate adapter cleanup
  results, owned-process verification, pending GitHub run settlement,
  repository-lease release, and the live-profile invariant after-check.

Every durable record is redacted before it is written: both scoped
credential values are scrubbed to `<redacted>` wherever they would otherwise
appear (configuration, environment dumps, subprocess diagnostics, or a
candidate's own output), and nothing under a run directory is ever readable
by another user (`0700`/`0600` throughout).

### The live-profile invariant (KTD15)

`start` captures a read-only snapshot of the **live** Herdr profile — the
one this playground must never touch — before any playground-owned resource
exists: its plugin registry, spaces/labels, sidebar rows, and session-socket
identity. `stop` captures the same snapshot again immediately before
releasing the repository lease and removing disposable runtime, and compares
the two. A run that reaches `active-ready` and tears down cleanly always
records a matching `before`/`after` pair. A mismatch — something changed the
live profile while the run was active, whether or not the playground caused
it — blocks teardown at `cleanup-incomplete` with
`LIVE_PROFILE_INVARIANT_MISMATCH` and preserves both snapshots for
inspection; nothing here is repaired automatically, since the playground
does not know what the correct live state should be.

## Deferred review states

Approved and changes-requested pull-request states are excluded from every
fixture catalog and every candidate observation by design (see "Fixture
ownership" above), not because of a bug or an oversight. A future unit that
introduces a second reviewer identity is the only place this should change.

## Retain-or-retire

This playground's own continued existence is not settled by finishing an
inventory. The follow-up sidebar-design work must explicitly decide to keep
it as a standing evaluation tool, or to retire the command, its fixtures,
and its tests once the accepted inventory has been captured elsewhere.
