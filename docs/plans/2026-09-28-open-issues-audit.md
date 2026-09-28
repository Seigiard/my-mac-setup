# Open issues audit

Audit the 26 open issues against the checkout and their GitHub discussion. GitHub remains the work tracker. This checklist records execution of this audit only.

For each group, read every issue and comment, check current source and relevant primary sources, update stale scope, and close only with evidence and a stated reason. Missing live evidence keeps an issue open. The parent verifies GitHub mutations and commits each outcome with its checkbox. Workers do not mutate GitHub, run verification, or commit.

## Progress

- [x] U1 · Agent permissions and isolation: #215, #232, #278; resolve the revmux/nono research and separate scope.
- [x] U2 · Review workflows: #243, #249, #284, #353.
- [x] U3 · Herdr and client integrations: #230, #239, #242, #250, #257.
- [x] U4 · Agent Intercom: #253, #294, #296, #297, #312, #313, #315, #316.
- [x] U5 · Environment maintenance and hooks: #247, #255, #262, #275, #347, #365.
- [ ] U6 · Verify coverage and cross-links, review the completed audit, and resolve clear findings.
      blocked 2026-09-28: se-code-review preflight refused the existing .codegraph symlink outside the scan root; no peer was launched. Resume after an operator decision on the scan boundary or review method.

## Done conditions

U1–U5: every listed issue has a source-grounded verdict; required GitHub edits and comments have been reread; the outcome below records links and evidence limits. U6: all 26 original issues are accounted for, review findings are resolved or explicitly left open, and the final documentation passes diff checks. This audit changes documentation and tracker state, not deployed behavior.

## Outcomes

### U1

- [#215](https://github.com/Seigiard/my-mac-setup/issues/215): updated permission proposal for `herdr-child ask` and atomic shell report delivery. Restricting Bash to the old callback alone would break that transport.
- [#232](https://github.com/Seigiard/my-mac-setup/issues/232): removed completed name allocation from remaining work; recorded resource-tree parentage and detached-reply guards. Attached control and malformed-response recovery remain open.
- [#278](https://github.com/Seigiard/my-mac-setup/issues/278): updated for PR #366's revmux migration while retaining the full child-path containment scope.
- Created [#368](https://github.com/Seigiard/my-mac-setup/issues/368) for revmux/nono evaluation. Production adoption stays in #278. Research: [nono confinement for revmux](../research/2026-09-28-revmux-nono.md).
- Evidence: source at `ccf423162ccf9f02a1854515bf0d949626e38e9d`, pinned upstream sources in the research, and local `revmux --version` / `revmux config`. Every mutation and comment was reread through GitHub. No sandbox or client experiment was run.

### U2

- [#243](https://github.com/Seigiard/my-mac-setup/issues/243): closed as superseded (`not planned`, `wontfix`). PR #366 removed the managed CE report-acceptance consumer; this does not claim a tested fix or removal of old live skill copies.
- [#249](https://github.com/Seigiard/my-mac-setup/issues/249) and [#353](https://github.com/Seigiard/my-mac-setup/issues/353): updated the source baseline for extended lenses and `efficiency`. Clarified nine versus ten experiment agents, concurrency policy, and missing-report attribution. Measurement work remains open.
- [#284](https://github.com/Seigiard/my-mac-setup/issues/284): retained and clarified ownership. The pair executable still treats failed tab closure as fatal before report publication, despite removal of its old named review consumers.
- Evidence: PR #366 / `13f06f5`, `home/private_dot_config/revmux/prompts/profiles/lean.md`, and `executable_se-external-leg-pair:158–179,519–522`. GitHub state, labels, bodies and comments were reread. No runtime reproduction was attempted.

### U3

- [#239](https://github.com/Seigiard/my-mac-setup/issues/239): updated and moved to `needs-info`. The old cwd record reader and the extracted sidebar location consumer differ. Define the producer/consumer contract before implementation.
- [#242](https://github.com/Seigiard/my-mac-setup/issues/242): updated notification policy, historical SDK evidence and short headless-session lifetime requirements.
- [#230](https://github.com/Seigiard/my-mac-setup/issues/230), [#250](https://github.com/Seigiard/my-mac-setup/issues/250), [#257](https://github.com/Seigiard/my-mac-setup/issues/257): retained existing scope; comments record remaining pilot/deployment evidence.
- Evidence: OpenCode adapter, Pi updater, Herdr installer/configuration, ADR-0020 and Pane Labels pin `aba61eb788c5fe0630dc570d96fd14683e2f63c7`. All five issue comments and both body changes were reread; no client/UI/remote deployment probe was run.

### U4

- [#253](https://github.com/Seigiard/my-mac-setup/issues/253): moved closed #314 to delivered work with the startup-fix evidence limit; updated the deduplication follow-up.
- [#294](https://github.com/Seigiard/my-mac-setup/issues/294): replaced redundant blanket-wrapper implementation with per-adapter assessment; moved to `ready-for-human`. Pinned OpenCode/Pi already have bounded, session-scoped deduplication.
- [#312](https://github.com/Seigiard/my-mac-setup/issues/312): limited restart claims to measured clients; Pi behavior remains a separate probe.
- [#315](https://github.com/Seigiard/my-mac-setup/issues/315): corrected the inert-team assumption and recorded outstanding documentation corrections and the landed Pi loader fix. No live probe requirement was removed.
- [#316](https://github.com/Seigiard/my-mac-setup/issues/316): updated the launch matrix for Claude enrollment/relaunch and intentional or incomplete-runtime bypasses.
- [#296](https://github.com/Seigiard/my-mac-setup/issues/296), [#297](https://github.com/Seigiard/my-mac-setup/issues/297), [#313](https://github.com/Seigiard/my-mac-setup/issues/313): retained unresolved deployment decisions with source-grounded comments.
- Evidence: current launcher and runtime pins, ADR-0018, versioned adapter sources linked in the issues. All eight comments and five body changes were reread. No new lifecycle or placement observation was claimed; ADR/managed-contract corrections are explicitly assigned to #312/#315, not applied in this tracker audit.

### U5

- [#247](https://github.com/Seigiard/my-mac-setup/issues/247): removed the retired Stop hook from the inventory and corrected the assumed cleanup mechanism.
- [#255](https://github.com/Seigiard/my-mac-setup/issues/255): marked historical event-deletion SQL as unapproved for automation pending the installed-version replay/sync contract. Corrected VACUUM space and WAL-consistent backup requirements.
- [#262](https://github.com/Seigiard/my-mac-setup/issues/262): limited the upstream blocker to trusted-tap validation/readall; direct installation is reported unaffected. Moved to `needs-info` and added existing-machine cleanup requirements.
- [#275](https://github.com/Seigiard/my-mac-setup/issues/275): retitled around the supported upgrade boundary. Script removal is delivered; the original transition evidence and documentation work remain.
- [#347](https://github.com/Seigiard/my-mac-setup/issues/347): added stale deployed corpus-file handling while preserving the deployed-core test contract.
- [#365](https://github.com/Seigiard/my-mac-setup/issues/365): corrected the poll writer/current location and the termination oracle's normal-timeout ambiguity. Retained the historical failure and regression requirement.
- Evidence: current source, `c5116f2`/`ccf4231`, upstream tap issue #2, OpenCode event source at `3c893f0a166cfc433819b4eff65d2e6c7696a1c9`, and SQLite documentation linked in #255. All mutations/comments were reread. No DB, deployment or test workload was run; this audit adds zero tests because it changes no runtime behavior.

### U6 — blocked after final tracker verification

- Requeried every page of open issues. The final set is the original 26 minus #243 plus #368: still 26 open issues.
- Verified an audit comment on every original issue, one category/state label per issue, `not_planned` for #243, and reciprocal #278/#368 scope links. Totals: 19 original bodies updated, six scopes retained with comments, one closed, one new issue.
- The requested `se-code-review` was invoked once through `se-external-leg-pair` with medium complexity/high effort. Its mandatory initial scan refused before peer creation: `.codegraph` resolves outside the checkout to `/Users/seigiard/.omo/codegraph/projects/my-mac-setup-a6748612ff186e82`. Observed terminal marker: `AUDIT_PAIR_EXIT=2`. No peer report or resolved selection was published; no waiver was used.
- The owned supervisor pane was closed after observing completion. Private review prompts and launcher files were removed. Existing `.codegraph` was preserved.
- Verification is tracker rereads, source evidence and `git diff --check`. No runtime/deployment behavior changed, so a build, Docker apply or permanent test would not prove the audit's claims. The missing cross-model review is a blocker, not a passing review verdict.
