# The pf cycle — shared mechanics for `/pf-issue`, `/pf-research`, `/pf-spec`, `/pf-build`

Not a command. This file holds the mechanics shared by the development cycle so each command file states them once. The cycle has two entries: `/pf-research` for a product change, `/pf-issue` for a reported defect. Both end at the same fork — `/pf-spec` when the change touches a contract, `/pf-build` when it stays inside the contracts. Each command tells you when to read this; follow it as part of that command. Building and publishing a narrative page (screenshots, HTML, rendered contract diffs) has its own file, `~/.claude/shared/pf-cycle-narratives.md`, which the commands that build pages read as well.

## The cycle

| Step           | Does                                                                                                                      | Artifact                                                            |
| -------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `/pf-issue`    | Audit a tracker issue against the contracts and the code; validate the top options with subagents. No repo changes.       | The **issue audit** — a markdown report the user decides on          |
| `/pf-research` | Gather everything relevant; narrate what is and what should become. No repo changes.                                      | The **research narrative** — an HTML page the user confirms          |
| `/pf-spec`     | Write the approved research into the product contracts; open the **epic PR**; iterate until it matches theory.            | Contract deltas in the epic PR + the **spec narrative**              |
| `/pf-build`    | Implement the contract spec in real code via opencode sub-issue PRs auto-merged into the epic branch; prove it live.      | The **demo** — walkthrough + discrepancy report vs the contract spec |

**The epic PR lifecycle:** `/pf-spec` opens it (base `main`, contracts only, green) and it **stays open**. `/pf-build` merges implementation PRs into its branch, so it grows into the single big PR carrying contracts + code. The **user** reviews that final PR with the demo and merges it — the only merge to `main` in the whole cycle. Merging to main deploys to prod; the cycle deliberately batches that into one reviewed moment.

## Linear is opt-in — the cycle tracks itself in local artifacts

By default the cycle creates **nothing in Linear**: no epics, no sub-issues, no comments, no attachments. The artifact directory (below) is the tracker — research narrative, spec narrative, sub-task files, statuses all live there. Reading Linear as history (a pre-existing epic, prior issues) is always fine. Writing to Linear happens only when the user **explicitly asks** for Linear tracking, or a pre-existing epic makes an attachment obviously wanted and the user confirmed the flow uses it. When Linear is used, the naming rules below apply, and one CLI caveat: Linear's renderer mangles round-trip patches (strips `**bold**` around code spans, auto-links bare domains, rewrites bullets) — never patch rendered text; edit the local file, re-push the whole description, re-fetch to verify.

## Naming on public surfaces

The cycle's terms — research narrative, contract spec, epic PR, demo — are plain engineering language, safe anywhere. Two rules still bind everything a teammate, reviewer, or external tool reads (PR titles and bodies, commit messages, branch names, Linear epic/issue titles, descriptions, and comments, GitHub review comments, prompts to implementation agents, and all visible text of published HTML pages):

- **Name the product change, not the process stage.** The epic PR is named for what it will contain when it merges: "PRD-1234: Deliverable views" passes; "Contract spec for deliverable views" fails. The same applies to Linear epic titles and published page titles.
- **Don't narrate the cycle.** Public text describes the product and the change; which command of the cycle produced it is irrelevant to the reader and never appears.

## Language

Two audiences, one artifact each.

- **English** — everything that leaves for the team or goes to a machine: every surface listed under **Naming on public surfaces**, the demo published to the team's host, `/pf-build`'s task files, and every prompt to a subagent or an opencode session.
- **The user's language** — everything else the cycle writes, because the user is its only reader: chat, `/pf-issue`'s `issue.md`, `/pf-research`'s `research.md` and `research.html`, `/pf-spec`'s `spec.md` and `spec.html`. That language is the one the user is addressed in: what their instructions name for replies, else the one they write in.

Nothing is translated. Each command reads its predecessor's file in the language it was written in, and writes contract deltas, PR text, task files and prompts as English from the start. When a narrative has to go to the team, build an English copy then, as a one-off.

Identifiers, paths, commands, contract terms, error text and code stay in English inside any page, whatever the page's language.

## Artifact storage

Every cycle's narratives live in `~/.claude/artifacts/<id>/` — never committed to the product repo. `<id>` is a short kebab topic slug by default; when a Linear epic or issue exists (pre-existing, or created on explicit request), use its id instead and rename a slug-named directory to it.

- Canonical sources: `issue.md` (with its `issue-source.md`, `context.md`, `candidates.md` working files), `research.md`, `spec.md`, `demo.md` (or a step-manifest in `build.ts`) plus captured images and `/pf-build`'s sub-task files under `tasks/`. **A later command reads the canonical source, not the built HTML** — keep sources current. Directories from cycles before 2026-08 may use the older names `divination.md` / `inscription.md` — read those when the new name is absent.
- Built pages: `research.html`, `spec.html`, `demo.html`.

## Deferred deltas

A **deferred delta** is a contract change that needs working code the epic PR can't yet carry — a gate would fail on it. Don't stub or fake it: `/pf-spec` records it in the spec narrative as the artifact file plus the precise entries/fields/values expected in its diff; `/pf-build` carries each one into the sub-task that implements it and verifies that diff at review.

## Missing-prior analysis — feedback handling

Every round of user feedback on any artifact of the cycle gets analyzed item by item, not just applied:

1. **Under-specified instruction** — the narrative/spec/instruction simply didn't say. Fine: apply the feedback, note it in the iteration log.
2. **Missing prior** — the repo context should already have told the AI: a standing convention, product fact, constraint, or taste the user has stated before or plainly holds as policy. Apply the feedback **and** write the prior into its single right home in the repository — repo `CLAUDE.md` only if every session needs it; otherwise the area `README.md`, the contract overview, or a skill. Ship it in the currently open PR when one exists, else a small standalone PR.

The test: *would a fresh session with no chat history have gotten this right from the repo alone?* If no, and the user expects it as standing policy, it is a missing prior. Log every item in the narrative's iteration ledger: feedback → classification → where the prior landed (or why none was needed).
