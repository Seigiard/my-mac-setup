---
title: Revmux benchmark harness corpus
type: benchmark
date: 2026-10-27
topic: revmux-benchmark-harness
status: candidate
---

# Revmux benchmark corpus

This manifest is the candidate input to issue #559. Labels and split assignments
remain provisional until the corpus is re-adjudicated and frozen.

| ID | Repository | Base..head | Kind | Seed source | Label status | Label basis | Split | Head source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| r249-positive-1 | `Seigiard/my-mac-setup` | `dbffb66d2a1b752ad186fc67164d53a0e47966b4..051d3de71401fb0b3ce6b8856f04f24c17b75244` | code | #249 range | positive | prior human verdict | unassigned | #249 range |
| r249-positive-2 | `Seigiard/my-mac-setup` | `806a7757a3093e95ea6514ef3e4767047cb8fdde..3eea07d62a73d99d82cf61d3e49f03f72674c5b0` | code | #249 range | positive | prior human verdict | unassigned | #249 range |
| r249-positive-3 | `Seigiard/my-mac-setup` | `cfe2e401fefae74195475911595b0d0f3085673d..68d8894ea7e1983b391b96b628c8370baad4e7ea` | code | #249 range | positive | prior human verdict | unassigned | #249 range |
| r249-positive-4 | `Seigiard/my-mac-setup` | `d0bb59d17b75cd160252f80669ea4711752337af..d080d3107262340e815302ac6dae957166b5b2e7` | code | #249 range | positive | prior human verdict | unassigned | #249 range |
| r249-clean-1 | `Seigiard/my-mac-setup` | `9c1416f..a492251` | code | #249 clean control | candidate | none yet | unassigned | #249 clean control (unresolved) |
| r249-clean-2 | `Seigiard/my-mac-setup` | `a492251..703c83a` | code | #249 clean control | candidate | none yet | unassigned | #249 clean control (unresolved) |
| r249-clean-3 | `Seigiard/my-mac-setup` | `703c83a..e5e671b` | code | #249 clean control | candidate | none yet | unassigned | #249 clean control (unresolved) |

The three clean-control ranges do not resolve in this checkout. They are kept
as re-identification records, not as runnable cases.

The remaining candidates come from reachable ordinary revmux tasks. Each entry
below records the source task's repository, branch and base. For archived rounds,
heads are resolved in this order: the range head in `input/scope.md`, the pull
request head from GitHub, and then the task's own branch at the round's finish
time. The moving `main` branch is never used as a head source. Unresolved heads
remain explicit branch names.

| ID | Repository | Base..head | Kind | Seed source | Label status | Label basis | Split | Head source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| archive-issue-509 | `Seigiard/my-mac-setup` | `12681fb18a8c550a1763eb27f4e6fc92eb6c0be6..7fd180b51006e05d51b1c71475732f8ec8d6664e` | code | ordinary task `issue-509` | candidate | none yet | unassigned | scope.md range (01-initial) |
| archive-issue-544 | `Seigiard/my-mac-setup` | `a54fd4d371da43a26958bea039cf3024bde3e799..worktree/calm-valley-8af9` | code | ordinary task `issue-544` | candidate (head unresolved) | none yet | unassigned | branch `worktree/calm-valley-8af9` (head unresolved) |
| archive-issue-545 | `Seigiard/my-mac-setup` | `a54fd4d371da43a26958bea039cf3024bde3e799..worktree/silver-forest-c55f` | code | ordinary task `issue-545` | candidate (head unresolved) | none yet | unassigned | branch `worktree/silver-forest-c55f` (head unresolved) |
| archive-issue-507 | `Seigiard/my-mac-setup` | `8cbf8f5bb17908aa1287ae8c86f684186573c60a..implement-507-fix-missing-wifi` | code | ordinary task `issue-507` | candidate (head unresolved) | none yet | unassigned | branch `implement-507-fix-missing-wifi` (head unresolved) |
| archive-issue-512 | `Seigiard/my-mac-setup` | `1d3391bbdbec4451435b7e0fdad22a44a9ad1d7a..issue-512-remove-opencode-v1` | code | ordinary task `issue-512` | candidate (head unresolved) | none yet | unassigned | branch `issue-512-remove-opencode-v1` (head unresolved) |
| archive-issue-520 | `Seigiard/my-mac-setup` | `60f2988e8bde8d979735b028a2c94650078dd7ff..implement-github-issue-520` | code | ordinary task `implement-github-issue-520` | candidate (head unresolved) | none yet | unassigned | branch `implement-github-issue-520` (head unresolved) |
| archive-feat-7 | `Seigiard/homelab` | `3995faf018962a993f5ecf23dc8abbfd48a18449..c9b8b751de8659c53661eab1af71621319092b70` | code | ordinary task `feat-7-container-drift` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-14T06:50:19.090865+02:00 origin/feat/7-container-drift |
| archive-feat-8 | `Seigiard/homelab` | `89a0952c5fc6819c864d3a0686237eb6000431df..d3e1dacd250bfbc413fb33c0839761991e408c77` | code | ordinary task `feat-8-disk-space` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-14T08:52:33.391026+02:00 origin/feat/8-disk-space |
| archive-feat-150 | `Seigiard/ttrpg-tools` | `96f109ed64cffcece097fab56228df32abe24698..497d27043843932d736284f0988d5ebf7fbb9260` | code | ordinary task `feat-150-mini-3d-render` | candidate | none yet | unassigned | branch `origin/feat/150-mini-3d-render` |
| archive-implement-151 | `Seigiard/ttrpg-tools` | `b672d300e3db6a5fc3590ebe9a6bb425102a2a8a..289835c4294ae944a2aefe3541b634cbfd45eac7` | code | ordinary task `implement-151-settings-header` | candidate | none yet | unassigned | branch `origin/implement-151-settings-header` |
| archive-pr-149 | `Seigiard/ttrpg-tools` | `d7870af2354662b730687a1d623169c525e69747..650afed6a0e23a202f447557c98bb2d9fabcf4a9` | code | ordinary task `pr-149` | candidate | none yet | unassigned | gh pr view 149 --repo Seigiard/ttrpg-tools --json headRefOid |
| archive-PRD-3579 | `membranehq/platform` | `a4a38f2b83203eab30affb1aa49aeead7b45b11c..c38972871d0b613263c5e1d36998345846a6899b` | code | ordinary task `PRD-3579` | candidate | none yet | unassigned | gh pr view 6487 --repo membranehq/platform --json headRefOid |
| archive-pr-6361 | `membranehq/platform` | `5a2303bf14bfcdde4b9b4f0a9fff460fe7e5f8f0..51822ad2fbbe8b9f47fd9c199b5721b4499cc1ba` | code | ordinary task `pr-6361` | candidate | none yet | unassigned | gh pr view 6361 --repo membranehq/platform --json headRefOid |
| archive-prd-3412 | `membranehq/platform` | `c89b72c00722c8757fdc32fa613c2eb1def197d8..8ecd156832c59d264c842ddeabf0b4f1ebcd90b3` | code | ordinary task `prd-3412-epic` | candidate | none yet | unassigned | gh pr view 6331 --repo membranehq/platform --json headRefOid |
| archive-prd-3488 | `membranehq/platform` | `4e96568c34ecb623b9b95ec1cc68068b8b4cd4ac..808e3e1849a1bda8f8bdd8e0d46dd94fb343fa04` | tests | ordinary task `prd-3488` | candidate | none yet | unassigned | gh pr view 6233 --repo membranehq/platform --json headRefOid |
| archive-prd-3603 | `membranehq/platform` | `40eb46e45206a7591fde65cd8a35d90f10887030..ec4a71d2e6925a3eebde461c31ce37c6ec968610` | code | ordinary task `prd-3603-epic` | candidate | none yet | unassigned | gh pr view 6582 --repo membranehq/platform --json headRefOid |
| archive-prd-3638 | `membranehq/platform` | `79810ee4977db9cae598ab493e2cd1bb027da4ec..6fbfb05e2fb126fa48dbdf270626fc9d250fb753` | code | ordinary task `prd-3638-partner-profile-preview` | candidate | none yet | unassigned | base: git merge-base 6fbfb05e2fb126fa48dbdf270626fc9d250fb753 origin/main; head: task branch |
| archive-PRD-3513 | `membranehq/platform` | `f5948586e7f682cc8d7bb9fd6b32a99bcf458f36..fb025b4d715ef317b034fc8f2be93a863b5c29b0` | code | ordinary task `PRD-3513` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-15T15:31:22.271656+02:00 prd-3513-bound-every-operator-cli-request-with-a-timeout |
| archive-prd-3390-console | `membranehq/platform` | `2bdabecd4c0b815b7c2a7bd7d831c4ef1f9584e6..8a2dfc1497849ae40415890a664d1d8fb57110db` | code | ordinary task `prd-3390-console-page-views-record-the-visit-source` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-20T12:00:40.403919+02:00 prd-3390-console-page-views-record-the-visit-source |
| archive-prd-3390-notification | `membranehq/platform` | `2bdabecd4c0b815b7c2a7bd7d831c4ef1f9584e6..a80b92579604098a00dd72f91d1a6e0fed01fcdb` | code | ordinary task `prd-3390-notification-links-carry-the-visit-marker` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-20T12:37:16.572222+02:00 prd-3390-notification-links-carry-the-visit-marker |
| archive-prd-3478 | `membranehq/platform` | `83d9c62cdec0709c054e2a589d902f8ec6be7c1a..7a372b0f9c74b52e6c9cceecb1d3a93ae8213f04` | tests | ordinary task `prd-3478` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-13T10:03:58.67349+02:00 prd-3478-make-workspaceelementlist-access-gated-selection-tests-deterministic |
| archive-prd-3492 | `membranehq/platform` | `357fdff0747a2745c7bb0ab39b88c25f307c78d1..prd-3492-a-new-connection-appears-only-after-a-page-reload` | code | ordinary task `prd-3492` | candidate (head unresolved) | none yet | unassigned | branch `prd-3492-a-new-connection-appears-only-after-a-page-reload` (head unresolved) |
| archive-prd-3494 | `membranehq/platform` | `357fdff0747a2745c7bb0ab39b88c25f307c78d1..599bd8a421ec31e106da4df8833095367f8588b1` | code | ordinary task `prd-3494` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-15T12:11:33.715459+02:00 prd-3494-connectioncreated-carries-no-organization |
| archive-prd-3495 | `membranehq/platform` | `357fdff0747a2745c7bb0ab39b88c25f307c78d1..ac81c1921c31b953ca0d0d87000a39ae32931df3` | code | ordinary task `prd-3495` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-15T12:11:41.649855+02:00 prd-3495-orgcreated-drops-the-referral-code |
| archive-prd-3498 | `membranehq/platform` | `357fdff0747a2745c7bb0ab39b88c25f307c78d1..a9f77bcf9068bc3718bf7f69e81822e31cbec9bf` | code | ordinary task `prd-3498-offer-links-lose-utm-tags-on-the-first-redirect` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-15T12:35:05.272725+02:00 prd-3498-offer-links-lose-utm-tags-on-the-first-redirect |
| archive-prd-3502 | `membranehq/platform` | `ed2ba8764013de4976e145b3808f8f2d5cfb5073..9f5d899b750ca11336331472cfc7e9c2594eda95` | code | ordinary task `prd-3502` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-15T16:32:07.378594+02:00 prd-3502-session-recording-never-starts-on-a-page-load-inside-a-workspace |
| archive-prd-3510 | `membranehq/platform` | `f5948586e7f682cc8d7bb9fd6b32a99bcf458f36..44e0a9f6b9902281f81638dc899cbce7d30bab1d` | code | ordinary task `prd-3510-orgcreated-referral-code` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-15T15:29:51.135804+02:00 prd-3510-orgcreated-referral-code |
| archive-prd-3511 | `membranehq/platform` | `09eec7186365c524ead7e045f34f7428601298ba..20ec458c20ec7f2af6e911f084663b51aa195654` | code | ordinary task `prd-3511-fix-retried-org` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-15T15:12:46.052437+02:00 prd-3511-fix-retried-org |
| archive-prd-3515 | `membranehq/platform` | `5a2303bf14bfcdde4b9b4f0a9fff460fe7e5f8f0..77326e1b3706bac8d364f363bea695e1205cc065` | code | ordinary task `prd-3515` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-16T07:59:27.51085+02:00 prd-3515-a-failed-prepared-workspace-hand-out-stays-taken-after-the-retry-window |
| archive-prd-3523 | `membrane ux-chain (api.membrane.agency …/code.git)` | `a0d0b6ace29d76e43923436d86334e000c2b8238..481a34ea5cbc32df1ca8097cd67c129e4cfb632d` | code | ordinary task `prd-3523-classifier-explains-view-switches-pressed-round-trips` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-15T19:24:56.340147+02:00 prd-3523-classifier-explains-view-switches-pressed-round-trips |
| archive-prd-3552 | `membrane ux-chain (api.membrane.agency …/code.git)` | `6236907fdcc9877809df23fdb8274ab4dd691db2..prd-3552-a-not-reproduced-issue-is-canceled-by-the-reproduce-turn` | code | ordinary task `prd-3552` | candidate (head unresolved) | none yet | unassigned | branch `prd-3552-a-not-reproduced-issue-is-canceled-by-the-reproduce-turn` (head unresolved) |
| archive-prd-3567 | `membrane ux-chain (api.membrane.agency …/code.git)` | `3045ff4487c721d34484b35fc2ab26181743e647..8f4ab5a217447ee7f8abd707e063f97c04618228` | code | ordinary task `prd-3567` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-19T11:52:34.714887+02:00 prd-3567-the-file-routine-reads-candidate-threads-a-few-at-a-time |
| archive-prd-3610 | `membranehq/platform` | `efdac2e80200414d7c0aa05387569162a7232fae..2554ff8bce610067ae407288c0695c61c5a1169d` | code | ordinary task `prd-3610-fix-dev-stack` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-22T13:15:48.166642+02:00 prd-3610-fix-dev-stack |
| archive-prd-3630 | `membranehq/platform` | `bf7bef2b7854aface78a3fa1ddab77e51a46a38e..08db5aedf3c23098840fb4474e10883f80871c6c` | code | ordinary task `prd-3630-filtered-elementlist-consumers-rarely-pass-elementlistnomatch` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-21T17:46:36.11151+02:00 prd-3630-filtered-elementlist-consumers-rarely-pass-elementlistnomatch |
| archive-prd-3669 | `membrane ux-chain (api.membrane.agency …/code.git)` | `733b62e7cb1340e48ef3fc6d95f7dcefc98ed15b..prd-3669-filter-bots-email-scanners-and-our-own-sessions` | code | ordinary task `prd-3669-filter-bots` | candidate (head unresolved) | none yet | unassigned | scope.md range (01-initial; head unresolved) |
| archive-prd-3672 | `membranehq/platform` | `4bdce06aa7cf133b8d95e10e798d0ec6d4a6b555..5f908a5ce8a93aee8ccd4897208c55309fe74727` | code | ordinary task `prd-3672-offer-page-name` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-26T16:23:37.509575+01:00 prd-3672-offer-page-name |
| archive-prd-3675 | `membrane ux-chain (api.membrane.agency …/code.git)` | `7d1abefc0902ed93a1f804a96d0929c7fc0bccdc..7bd139ade55cec77a00e6d31fe47f33cc926d65a` | code | ordinary task `prd-3675-visitor-road-a-funnel-share-below-1-reads-as-0` | candidate | none yet | unassigned | git rev-list -1 --before=2026-10-26T16:48:53.768844+01:00 origin/prd-3675-visitor-road-a-funnel-share-below-1-reads-as-0 |

Tasks for repositories without a local clone (including `ttrpg-typst`,
`ttrpg-map-viewer`, `opds-generator`, `obsidian-tinymist`, `herdr-pane-labels`,
and `herdr-worktree-setup`) are skipped because their GitHub URLs were not
cloned here. The composition is frozen by issue #559 after re-adjudication,
not by this seed manifest.
