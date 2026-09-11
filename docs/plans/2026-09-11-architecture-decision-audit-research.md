---
title: Architecture Decision Audit - Research
type: research
date: 2026-09-11
topic: architecture-decision-audit
status: complete
execution: none
---

# Architecture Decision Audit - Research

## What this document is

This is an audit of the current repository and its local Git history for
intentional architectural decisions that are consequential, expensive to
reverse, and not already captured adequately under `docs/decisions/`. It does
not create or propose ADR text. It identifies the evidence that a later
`/grill-with-docs` or `/domain-modeling` pass should use.

The audit distinguishes three outcomes:

- **write ADR now** — the repository contains enough evidence to record the
  decision, its rationale, alternatives, and accepted costs without inventing
  intent;
- **confirm with maintainer** — the mechanism is consequential, but the reason
  for choosing it or its current status is incomplete or contradictory;
- **skip** — the item is local, already documented adequately, superseded, or
  too foundational to represent a useful live choice.

The current decision corpus contains three records:

- `docs/decisions/0001-se-pipeline-architecture-redirection.md` is explicitly
  rejected and retained as history after the Smithers runtime was removed.
- `docs/decisions/0002-guard-the-idempotency-suite-with-a-disposable-home-marker.md`
  is accepted and narrowly owns the disposable-home authorization boundary.
- `docs/decisions/0003-context-growth-is-an-ambient-signal-not-a-halt.md`
  records a current decision, but unlike 0001 and 0002 it has no frontmatter or
  explicit status field. That format inconsistency should be settled before the
  corpus grows; it is not itself an architectural candidate.

## Method and evidence boundary

The audit read the current source, tests, plans, learnings, issue records, and
the history of the relevant paths. Commit messages are used to establish that a
mechanism was deliberately introduced or replaced; current source establishes
that it still exists. Plans count as rationale evidence, not as substitutes for
a searchable decision index.

The working baseline was `1034575` (`chore(skills): add data-structures
error-handling js-gof`). Pre-existing uncommitted changes to `CLAUDE.md` and the
untracked `docs/agents/` directory were not treated as authoritative evidence
for any candidate. No remote PR discussion or private session transcript was
consulted.

---

## Candidate summary

| Priority | Candidate | Recommendation | Main reason |
|---:|---|---|---|
| 1 | Persist a machine role and keep the server free of a persistent outbound SSH key | **write ADR now** | Security boundary, three-machine rollout, and explicit accepted forwarding risk |
| 2 | Centralize cross-client hook policy in one client-neutral, fail-open core | **write ADR now** | One enforcement model governs three clients and deliberately accepts silent policy failure |
| 3 | Separate unattended chezmoi verification into full-fixture and host-partial profiles | **write ADR now** | Security, automation, and coverage-honesty boundary with explicit rejected alternatives |
| 4 | Keep repository issues as validated Markdown records instead of using a hosted tracker | **write ADR now** | Repository-wide workflow and schema with migration and CI coupling |
| 5 | Give Herdr sole ownership of interactive worktrees and authorize generated-branch renames with a lifecycle marker | **write ADR now** | Cross-process ownership boundary replacing an earlier worktree mechanism |
| 6 | Pin externally fetched artifacts and require explicit reviewed updates | **write ADR now** | Repository-wide reproducibility and supply-chain posture |
| 7 | Split the global skill namespace between the upstream Skills CLI and chezmoi-owned skills | **confirm with maintainer** | Consequential two-owner namespace, but the reason for retaining two owners is not recorded |
| 8 | Retain bashunit with a permanent Bats-compatibility DSL | **confirm with maintainer** | Current architecture is clear, but the accepted benchmark missed the plan's stated 30% gate |
| 9 | Allow external peer launches without one universal pre-dispatch secret boundary | **confirm with maintainer** | Current state is a known open security decision, not a settled architecture |

---

## Candidates recommended for an ADR now

### 1. Persist a machine role and keep the server free of a persistent outbound SSH key

**Observed decision.** A chezmoi installation binds exactly one role from
`mbp2021`, `mbp2026`, or `server`; the role is OS-constrained and drives a
committed SSH topology. Laptops use their own 1Password-backed identities. The
server stores no persistent outbound private key and receives temporary Git
authentication only through an explicit, non-multiplexed forwarded-agent
session.

**Why this is ADR-worthy.** This is both an identity model and a security
boundary. Adding or changing a machine affects initialization, persisted state,
role validation, ignored paths, SSH client configuration, inbound
authorization, CI fixtures, and rollout procedures. Replacing the server's
forwarded-agent model with a permanent key changes the compromise boundary.

**Concrete evidence.**

- `home/.chezmoi.yaml.tmpl:16-30` defines the closed role set and fails on an
  unknown or OS-incompatible role.
- `home/.chezmoidata/ssh.yaml:1-35` maps roles to Tailscale names, users,
  1Password selectors, and complete inbound authorization sets.
- `docs/plans/2026-09-09-0900-feat-role-based-ssh-access-plan.md:27-56`
  states the role model, the no-private-key server policy, and the accepted
  whole-agent-forwarding risk.
- The same plan's KTD1-KTD4 (`:74-80`) define persistence, committed public
  topology, the client role matrix, and omission of the server-side 1Password
  agent configuration.
- Commit `232fec8` introduced the shipped mechanism; `a895420` immediately
  corrected a role-specific account, illustrating that role data is operational
  configuration rather than illustrative documentation.

**Evidenced alternatives and rationale.** The plan records three choices:
chezmoi ownership instead of three independent SSH configurations, no permanent
server identity, and explicit forwarding instead of provisioning one. It also
rejects automating daemon, firewall, Tailscale, `known_hosts`, and live rollout
concerns into this policy.

**Uncertainty.** The repository proves rendering and policy, but it cannot prove
that the attended live matrix has been completed on all three machines. An ADR
must describe the selected architecture without claiming rollout evidence that
is not committed.

**Recommendation: write ADR now.** Suggested title: **Bind SSH policy to a
persisted machine role and keep the server keyless**.

### 2. Centralize cross-client hook policy in one client-neutral, fail-open core

**Observed decision.** Claude Code, OpenCode, and Pi use thin transport adapters
over one Bun/TypeScript policy core. Client-specific tool spellings and outcome
capabilities live in registry profiles; policy modules do not name clients.
Applicability is derived statically. Every import, normalization, dispatch, and
policy-exception failure allows the intercepted tool call to proceed.

**Why this is ADR-worthy.** This design controls safety checks across every
supported coding-agent client. Its most important property is also its accepted
risk: a broken guard fails open, sometimes silently. Changing to fail-closed or
returning to per-client policy copies would materially alter reliability,
operator friction, and coverage guarantees.

**Concrete evidence.**

- `home/dot_local/lib/agent-hooks/index.ts:1-2,49-66,78-94` implements ordered
  dispatch, first-deny wins, and fail-open behavior at both policy and pipeline
  boundaries.
- `home/dot_local/lib/agent-hooks/index.ts:23-44` reads the disable escape hatch
  only from the client process environment so an intercepted call cannot disable
  its own policy.
- `home/dot_local/lib/agent-hooks/registry.ts:17-45` records client-specific
  names and capabilities; Pi deliberately omits an unverified `fff-grep` route.
- `home/dot_local/lib/agent-hooks/registry.ts:75-93` derives applicability from
  tool presence and supported outcomes instead of hand-declaring coverage.
- `docs/plans/2026-09-03-0833-feat-agent-hooks-core-plan.md:24-30,46-65`
  defines the one-core contract, static inapplicability, fail-open safety, and
  process-environment-only escape hatch.
- Commit `e2f7bd5` replaced the previous client-specific enforcement with the
  shared implementation.

**Evidenced alternatives and rationale.** KTD1-KTD10 in the plan (`:96-108`)
record the rejected alternatives: continue three hand-written implementations,
adopt a larger capability-negotiation runtime, keep Bash engines as subprocess
dependencies, use a broad Claude matcher, use per-call dynamic imports, or
adopt `pi-hooks` and make Claude's hook format canonical.

**Uncertainty.** The ADR must preserve the named coverage gaps rather than imply
universal enforcement: OpenCode subagent calls bypass hooks, Pi and Claude
subagent behavior was not fully verified at planning time, and input-dependent
policy exceptions have no durable log (`docs/plans/2026-09-03-0833-feat-agent-hooks-core-plan.md:74-90`).

**Recommendation: write ADR now.** Suggested title: **Use one client-neutral,
fail-open core for coding-agent hook policies**.

### 3. Separate unattended chezmoi verification into full-fixture and host-partial profiles

**Observed decision.** Every repository-owned non-interactive chezmoi call must
cross one launcher and name either `full-fixture` or `host-partial`.
`full-fixture` requires a disposable home and all repository-owned canary
credentials, then renders every registered secret-sensitive target.
`host-partial` omits those targets, reports the omission, and never claims that
the host diff verified them. Interactive use retains 1Password lookup.

**Why this is ADR-worthy.** The profile split defines what automated evidence
means. It prevents an agent or CI process from waiting for interactive
1Password authorization, prevents unavailable credentials from being
misinterpreted as deletion, and prevents a partial host diff from being reported
as complete verification.

**Concrete evidence.**

- `tests/helpers/chezmoi-unattended:20-57` requires explicit unattended mode
  and an explicit profile; `:66-142` validates the central target inventory;
  `:144-160` independently checks profile and write authority.
- `home/dot_zshenv.tmpl:96-124` branches before secret evaluation among
  full-fixture, host-partial, invalid-unattended, and interactive 1Password
  paths.
- `home/modify_dot_claude.json:15-46,58-67` avoids interactive failure becoming
  a whole-apply failure and preserves existing credentialed entries when an
  unattended replacement is absent.
- `Makefile:31-38,65-73` routes disposable rendering through full fixtures and
  makes the host path an explicitly partial, diff-only operation.
- `docs/plans/2026-09-04-1126-fix-unattended-chezmoi-plan.md:37-53`
  records the failure, the profile split, and credential-preservation decision;
  KTD1-KTD9 (`:173-185`) record the executable-boundary design.
- Commit `cbccaa6` is the integration point; the plan also records the unit
  commits that introduced the launcher and profile-aware templates.

**Evidenced alternatives and rationale.** The plan rejects PATH surgery, a
1Password service account, timeout-based control, making all unattended runs
skip secrets, and comparing fixture values to live host secrets. Full fixtures
are chosen for disposable completeness; host omission is chosen for an honest
comparison that does not expose or rewrite live credentials.

**Uncertainty.** The plan shows U6 unchecked even though the integration commit
is on current history. The current source demonstrates that the mechanism
shipped, but an ADR should not copy the plan's progress checklist as present
state. Chezmoi 2.72.1 behavior remains an explicit compatibility dependency.

**Recommendation: write ADR now.** Suggested title: **Use explicit full-fixture
and host-partial profiles for unattended chezmoi execution**.

### 4. Keep repository issues as validated Markdown records instead of using a hosted tracker

**Observed decision.** `docs/issues/` is the source of truth for repository
work. A standard-library Python CLI owns structured reads, validation, and
lifecycle mutation; Git owns history and collaboration; CI rejects invalid
records. Free-form prose search remains available, but structured operations go
through the CLI.

**Why this is ADR-worthy.** The choice governs backlog ownership for humans and
all three agent clients. Reversing it means migrating the issue corpus,
replacing the CLI and its tests, changing contribution workflows, and removing
repository gates. The local model also accepts the absence of hosted-tracker
primitives such as native labels, comments, relations, notifications, and
boards.

**Concrete evidence.**

- `scripts/issues:1-31` defines a repository-local parser and closed schema for
  type, state, subsystem category, and priority; the rest of the executable
  implements reads and protected mutations.
- `Makefile:24-26,31-35,75-77` makes issue validation part of the focused,
  Ubuntu, template, and Docker entry points.
- `docs/plans/2026-08-21-001-feat-repository-issue-management-plan.md:15-45`
  explicitly selects repository-local Markdown, one cross-client contract, a
  deterministic CLI, and filename-derived identity.
- The plan's scope boundary (`:168-176`) excludes an external tracker, hosted
  service, board, or daemon; its assumptions (`:179-185`) name Git as the
  history and collaboration layer.
- Commit `cc4774a` introduced repository issue management; subsequent commits
  `5efad91`, `dcd4118`, and `5f171c9` refined its human-facing list output rather
  than replacing the storage model.

**Evidenced alternatives and rationale.** The plan explicitly chooses local
records over an external tracker and replaces the drifting hand-maintained
`_open-issues.md` snapshot with derived views. It keeps `rg` for prose while
rejecting ad hoc text pipelines for lifecycle or multi-field queries.

**Uncertainty.** The repository does not record a product-by-product comparison
with GitHub Issues or Linear. The plan is enough to establish the local choice
and its desired properties, but the ADR should label any claim about why one
specific hosted product was rejected as inference. The presence of Linear
tooling proves availability, not that Linear was formally evaluated.

**Recommendation: write ADR now.** Suggested title: **Use validated Markdown
records as the repository issue tracker**.

### 5. Give Herdr sole ownership of interactive worktrees and gate generated-branch renames on a lifecycle marker

**Observed decision.** Herdr owns interactive worktree creation, opening,
closing, and removal. A repository plugin handles post-create setup and writes a
marker into the linked worktree's Git administrative directory. Task-derived
branch renaming is permitted only when that lifecycle-owned marker proves that
Herdr generated the checkout; a `worktree/*` prefix alone is insufficient.

**Why this is ADR-worthy.** This is an ownership and authorization boundary
across Git, Herdr, shell tooling, plugins, and agent identity. A false-positive
rename mutates user-owned Git metadata; a false-negative leaves generated names
behind. The marker makes provenance, rather than naming convention, the
authority.

**Concrete evidence.**

- `docs/herdr-worktrees.md:1-7` assigns lifecycle, task-derived Git metadata,
  workspace titles, and agent aliases to distinct owners.
- `docs/herdr-worktrees.md:18-29` limits the plugin to setup, records the
  `herdr-generated-worktree` marker, and explains why a branch prefix cannot
  authorize rename.
- `docs/herdr-worktrees.md:31-55` records per-repository setup policy and the
  fail-closed conditions for fresh-base mutation.
- `docs/herdr-worktrees.md:57-66` assigns deployment ownership to chezmoi and
  records the working-checkout/source-clone separation.
- Commit `4adc681` moved lifecycle to native Herdr worktrees; `64f42fe` added
  task-derived generated-worktree naming; `cfe2e40` tightened identity and
  alias validation after the initial implementation.

**Evidenced alternatives and rationale.** The current document names the former
Worktrunk mechanism and the ownership split that replaced it. The marker check
rejects the weaker alternative of authorizing from a branch-name prefix. The
fresh-base policy also rejects mutating checkouts that track an upstream, match
a remote branch, contain files, or cannot be refreshed safely.

**Uncertainty.** The current documentation is strong on mechanism and safety,
but the high-level reason for choosing native Herdr lifecycle over keeping
Worktrunk is distributed through history rather than stated in one paragraph.
The ADR should derive that comparison only from the migration commits and
current ownership model, not invent operational complaints.

**Recommendation: write ADR now.** Suggested title: **Make Herdr the sole owner
of interactive worktrees and authorize generated identity by marker**.

### 6. Pin externally fetched artifacts and require explicit reviewed updates

**Observed decision.** Chezmoi externals use immutable commit or release URLs;
binary artifacts carry per-platform checksums; updates are explicit repository
edits rather than automatic refreshes. Update automation may prepare and publish
reviewable pin changes, but the managed source remains the authority.

**Why this is ADR-worthy.** These artifacts execute in the user's shell or agent
environment. Mutable upstream state would make identical repository revisions
produce different machines. The policy also determines bootstrap dependencies:
some tools must remain installable in the minimal CI environment before the
normal toolchain exists.

**Concrete evidence.**

- `home/.chezmoiexternal.toml:1-3` states the repository-wide explicit-update
  policy.
- `home/.chezmoiexternal.toml:5-40` pins Oh My Zsh and four plugins to immutable
  revisions while documenting the parent/child `exact` ordering invariant.
- `home/.chezmoiexternal.toml:42-74` pins `fff-mcp` to a release with four
  architecture-specific SHA-256 values and replaces the vendor's `curl | bash`
  installer.
- Commits `6cf962e`, `a8a8497`, and `58147fc` are reviewable pin-only changes;
  `7a395d5` fixes publication of accepted pin bumps rather than restoring
  mutable updates.

**Evidenced alternatives and rationale.** The file explicitly rejects mise's
`ubi/github` backend for `fff-mcp`: the binary must install when mise is absent
in minimal CI, and the external carries checksum guarantees that backend does
not. It also rejects an exact parent archive because chezmoi would delete
separately managed plugin children.

**Uncertainty.** The rationale is strongest for `fff-mcp` and the Oh My Zsh
tree. The general pinning rule is explicit, but a broad ADR should not claim
that every external underwent the same alternatives analysis.

**Recommendation: write ADR now.** Suggested title: **Pin fetched artifacts and
make external updates explicit repository changes**.

---

## Candidates requiring maintainer confirmation

### 7. Split the global skill namespace between the upstream Skills CLI and chezmoi-owned skills

**Observed decision.** Upstream skill selections live in
`home/private_dot_config/agent-skills/manifest` and are installed into
`~/.agents/skills` by the Skills CLI, whose global lock owns those children.
Repository-authored skills are deployed by chezmoi into the same effective
namespace. A second manifest reserves their names so wildcard upstream installs
cannot claim them. Claude receives symlink adapters; OpenCode and Pi discover
the canonical tree natively.

**Why this is ADR-worthy.** Two independent deployment systems share one global
namespace. A missed reservation can turn a wildcard update into a silent owner
collision, while consolidating on either owner would change update, pinning,
discovery, and deployment behavior across three clients.

**Concrete evidence.**

- `home/private_dot_config/agent-skills/manifest:1-11` includes both selected
  skills and wildcard sources.
- `home/private_dot_config/agent-skills/repository-owned:1-19` states that the
  list must stay synchronized with `home/private_dot_agents/skills` so wildcard
  installs cannot claim a chezmoi-owned tree.
- `docs/agent-setup-inventory.md:6-16` names the two owners, the upstream lock,
  client discovery paths, and the no-dual-owner invariant.
- `docs/agent-setup-inventory.md:24-38` defines synchronization behavior and
  deliberately makes `sync` report drift without deleting it.
- Commit `ff078be` introduced persisted manifest choices; later `chore(skills)`
  commits continue to update that model.

**Evidenced alternatives and rationale.** Collision avoidance and non-destructive
sync are explicit. The repository does not explain why repository-owned skills
cannot also be installed through the Skills CLI, or why all skills cannot be
owned by chezmoi. Those are the alternatives an ADR must compare.

**Uncertainty.** The mechanism is clear but the two-owner choice is not. A
maintainer may regard it as an imposed boundary between upstream and local
content rather than a considered architecture.

**Recommendation: confirm with maintainer.** Ask why two owners are retained and
what property would be lost by consolidating before drafting an ADR.

### 8. Retain bashunit with a permanent Bats-compatibility DSL

**Observed decision.** The production post-apply suite runs on vendored
bashunit 0.50.1 while retaining Bats command-capture and assertion vocabulary in
a permanent 520-line compatibility DSL. Files execute sequentially, tests may
run in parallel within a file, and Bats remains installed for nested-runner
scenarios.

**Why this is ADR-worthy.** The repository accepted a permanent compatibility
surface, preserved known Bash 3.2/Bats quirks, and excluded converted tests from
normal shellcheck treatment in exchange for lower wall-clock time. Reversing the
decision touches every shell suite and its execution model.

**Concrete evidence.**

- `tests/bashunit/test-dsl.bash:1-31` explicitly calls the compatibility layer
  permanent and defines the hybrid vocabulary and preserved semantics.
- `tests/run-post-apply.sh:1-15` makes the pinned runner and approximately 24%
  wall-clock reduction the production contract.
- `docs/benchmarks/bashunit-full-suite-experiment.md:13-32` reports 403/403
  parity and reductions of 24.1% on macOS and 24.4% in Docker, plus the retained
  compatibility costs.
- `Makefile:79-87` excludes converted tests from shellcheck and retains a custom
  assertion checker.
- Commit `051d3de` cut production execution over after the benchmark; `dbffb66`
  records the preceding suite-time optimization.

**Evidenced alternatives and rationale.** The plan requires an A/B evaluation
instead of immediate rewrite, keeps Bats as the immutable oracle, and allows a
rejected candidate to leave only a report. The benchmark records why a native
bashunit rewrite was not behaviorally equivalent and why a compatibility DSL
was required.

**Uncertainty and contradiction.** The pre-registered plan says adoption
requires at least 30% improvement on both platforms and says to stop if either
platform misses (`docs/plans/2026-08-26-002-perf-bashunit-test-migration-plan.md:15-22,40-45,62-78`).
The accepted report calls a roughly 24% improvement a win
(`docs/benchmarks/bashunit-full-suite-experiment.md:15-25,140-155`). The report
does not state that the threshold was amended or waived. That gap prevents an
audit from truthfully reconstructing the final decision authority.

**Recommendation: confirm with maintainer.** Ask whether the 30% gate was
explicitly relaxed, whether a different workload became authoritative, or
whether the migration should be treated as an exception. Record that answer in
the ADR rather than silently rewriting the historical plan.

### 9. Allow external peer launches without one universal pre-dispatch secret boundary

**Observed decision.** Current `se-*` and consultation workflows can launch
Claude and OpenCode peers over the live checkout. Only `se-doc-review` performs
a fail-closed `gitleaks` scan, and it scans one document rather than the complete
tree. The universal two-tier boundary formerly owned by Smithers was deleted
with that runtime and was not replaced.

**Why this is ADR-worthy.** Repository content crosses a third-party boundary
and cannot be recalled. The choice between a universal full-tree gate,
payload-specific checks, explicit exemptions, or accepted unscanned exposure is
a security architecture decision, not merely a test gap.

**Concrete evidence.**

- `docs/issues/2026-09-04-001-pre-external-secret-scan-covers-one-of-five-external-peer-launch-paths.md:12-42`
  inventories five current paths and records the Smithers-era regression.
- The issue's scope and open decisions (`:44-68`) explicitly ask whether the
  gate should be shared or caller-specific and what each caller exposes.
- `docs/solutions/architecture-patterns/pre-external-secret-boundary-for-coding-agent-pipelines.md:130-147`
  says the old gate was removed and current implementation no longer satisfies
  the documented boundary.
- Commit `9376add` removed Smithers and the prior gate; ADR-0001 records the
  runtime's rejection but does not decide whether its security boundary should
  survive independently.

**Evidenced alternatives and rationale.** The open issue identifies a shared
gate in `herdr-peer-launch.md`, per-caller payload-scoped gates, and explicit
caller exemptions. The learning document supplies the prior fail-closed,
redacted, pinned-exit-code, full-tree rationale.

**Uncertainty.** This is intentionally unresolved and tracked as an open,
high-priority bug. Writing an ADR that describes the current omission as an
accepted risk would manufacture a decision; writing one that mandates the old
gate would pre-empt the open design choice. The learning document also contains
one stale sentence saying no issue tracks the regression, although the issue now
exists.

**Recommendation: confirm with maintainer.** Resolve the open decision first;
then write an ADR for the selected external-content boundary, not for the
accidental interim state.

---

## Items considered and skipped

### Explicit-only workflows use one body and client-specific manual adapters

**Observed decision.** Claude and Pi receive skills with
`disable-model-invocation: true`; OpenCode receives commands because it does not
honor that metadata; OpenCode's Claude-skill discovery is disabled globally.

**Why skip.** The complete rationale and alternatives are already current in
`docs/plans/2026-08-23-001-feat-preserve-explicit-only-skills-across-agent-clients-plan.md:27-48,99-121`,
the live adapters are only five to seven lines, and the operational rule is in
`docs/agent-setup-inventory.md:18-19` plus source comments at
`home/dot_zshenv.tmpl:81-87`. The plan explicitly chose active guidance because
future agents must encounter the rule during ordinary work. An ADR would add an
index entry, but little missing reasoning.

**Recommendation: skip.** Revisit only if a third explicit-only packaging shape
appears or a client changes the invocation model.

### Herdr child supervision and child-initiated callbacks

**Observed decision.** Child control uses explicit attached/detached modes,
child-initiated callbacks, identity triples, generation epochs, and one external
watcher per detached child.

**Why skip.** The decision and alternatives are already unusually complete in
`docs/solutions/architecture-patterns/child-initiated-callback-over-in-turn-supervision.md`,
`home/private_dot_claude/shared/child-agent-contract.md`, and
`docs/plans/2026-09-05-herdr-child-lifecycle-simplification-research.md`. The
latter maps six state machines and concludes that the complexity is the cost of
the protocol rather than accidental duplication. Promoting that analysis into
`docs/decisions/` may improve filing consistency, but this audit found no
missing rationale to reconstruct.

**Recommendation: skip.** If the maintainer wants every architectural decision
indexed only under `docs/decisions/`, treat that as documentation migration, not
new decision research.

### Chezmoi as the repository substrate

**Observed decision.** The repository's managed source lives under `home/`, and
chezmoi naming, templates, scripts, externals, and the source/deployed/live
three-copy model shape nearly every path.

**Why skip.** Commit `ea7941a` introduced the current cross-platform chezmoi
structure, Docker tests, CI, and managed configuration together. No earlier
alternatives analysis survives in the repository, and the decision is now the
project's premise rather than a live seam. An ADR could explain chezmoi, but it
could not recover why chezmoi was selected without maintainer memory.

**Recommendation: skip.** Keep the operational three-copy warning in active
guidance; write a retrospective ADR only if the substrate is reconsidered.

### Host apply prohibition and disposable-home testing

**Observed decision.** Agents never apply this checkout to the real host;
`make test-local` is diff-only, and real apply/idempotency coverage runs only in
an authorized disposable home.

**Why skip.** ADR-0002 already records the dangerous behavior, rejected
alternatives, exact marker, residual self-hosted-runner risk, and defense in
depth. `Makefile:65-73` adds the current host-safe execution details without
changing that decision.

**Recommendation: skip.** Expand or supersede ADR-0002 only if the host-apply
policy changes; do not create a competing ADR for the same boundary.

---

## Cross-cutting findings

### The plans are carrying decision history that the ADR index does not expose

The strongest six candidates are not undocumented in the literal sense. Their
rationale lives in large implementation plans, often under `Key Decisions` and
`Key Technical Decisions`. That preserves evidence but makes a future reader
know the feature date or filename before finding it. Short ADRs should point to
those plans rather than copy their full requirements.

### Current guidance mixes policy, deployment procedure, and rationale

Files such as `docs/agent-setup-inventory.md`, `docs/herdr-worktrees.md`, and
source comments are useful because agents encounter them during work. They
should remain. The ADR opportunity is to separate the stable choice and accepted
cost from the mutable procedure, not to move all documentation into
`docs/decisions/`.

### Security postures intentionally differ by blast radius

The repository contains both fail-open and fail-closed boundaries:

- agent hook policy exceptions fail open so a broken optional guard does not
  stop every tool call;
- invalid machine roles, disposable-home authorization, issue mutations, and
  credential-fixture completeness fail closed;
- external secret scanning is expected to fail closed where it exists, but is
  not present at every current external crossing.

An ADR should never summarize the repository as globally fail-open or globally
fail-closed. Each candidate must name its consumer and the consequence of a
false allow versus a false deny.

### One committed learning is stale

`docs/solutions/architecture-patterns/pre-external-secret-boundary-for-coding-agent-pipelines.md:147`
says no repository issue tracks the coverage regression.
`docs/issues/2026-09-04-001-pre-external-secret-scan-covers-one-of-five-external-peer-launch-paths.md`
now tracks it. This is documentation drift, not a new issue created by the
audit.

---

## Counts and prioritized next pass

### Outcome counts

- **9 ADR candidates assessed**
- **6 — write ADR now**
- **3 — confirm with maintainer**
- **4 additional items considered and skipped**
- **0 ADRs created by this audit**

### Prioritized shortlist for `/grill-with-docs` or `/domain-modeling`

1. **SSH role and keyless-server policy** — highest security and recovery blast
   radius; evidence and alternatives are complete.
2. **Client-neutral fail-open agent-hook core** — broadest agent-platform
   enforcement consequence; the ADR must preserve named coverage gaps.
3. **Unattended chezmoi profile split** — defines the meaning and safety of
   automated verification across Make, CI, Docker, and host diff.
4. **Repository-local issue tracker** — governs all backlog lifecycle and has a
   clear external-tracker alternative.
5. **Herdr worktree ownership and lifecycle marker** — prevents authority from
   being inferred from a branch-name convention.
6. **Pinned external artifacts** — captures the repository-wide supply-chain
   and reproducibility posture while the examples are current.

Before drafting candidate 7, ask why the skill namespace intentionally has two
owners. Before drafting candidate 8, resolve the 30%-versus-24% benchmark
contradiction. Before drafting candidate 9, decide the external secret boundary
through the existing high-priority issue.

## Limitations

- The audit used repository contents and local Git history only. It did not read
  GitHub PR comments, deleted private issue discussion, or coding-agent session
  archives.
- Commit history proves when mechanisms changed, but a commit subject alone is
  not treated as rationale.
- Current line references are snapshots of baseline `1034575`; later edits may
  move them.
- Uncommitted `CLAUDE.md` and `docs/agents/` content was deliberately excluded
  from candidate evidence so this note does not convert another workstream's
  local changes into established policy.
- The audit evaluates whether reasoning is missing, not whether every current
  architecture is desirable. In particular, the open external-secret boundary
  remains a decision to make rather than a decision to document.
