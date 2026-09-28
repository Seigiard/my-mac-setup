# Open issues audit

Audit the 26 open issues against the checkout and their GitHub discussion. GitHub remains the work tracker. This checklist records execution of this audit only.

For each group, read every issue and comment, check current source and relevant primary sources, update stale scope, and close only with evidence and a stated reason. Missing live evidence keeps an issue open. The parent verifies GitHub mutations and commits each outcome with its checkbox. Workers do not mutate GitHub, run verification, or commit.

## Progress

- [x] U1 · Agent permissions and isolation: #215, #232, #278; resolve the revmux/nono research and separate scope.
- [x] U2 · Review workflows: #243, #249, #284, #353.
- [ ] U3 · Herdr and client integrations: #230, #239, #242, #250, #257.
- [ ] U4 · Agent Intercom: #253, #294, #296, #297, #312, #313, #315, #316.
- [ ] U5 · Environment maintenance and hooks: #247, #255, #262, #275, #347, #365.
- [ ] U6 · Verify coverage and cross-links, review the completed audit, and resolve clear findings.

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
