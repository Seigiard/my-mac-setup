# The pf cycle — shared mechanics for `/pf-issue`, `/pf-research`, `/pf-spec`, `/pf-build`

Not a command. This file holds the mechanics shared by the development cycle so each command file states them once. The cycle has two entries: `/pf-research` for a product change, `/pf-issue` for a reported defect. Both end at the same fork — `/pf-spec` when the change touches a contract, `/pf-build` when it stays inside the contracts. Each command tells you when to read this; follow it as part of that command. Building and publishing a narrative page (screenshots, HTML, rendered contract diffs) has its own file, `~/.claude/shared/pf-cycle-narratives.md`, which the commands that build pages read as well.

## The cycle

| Step           | Does                                                                                                                      | Artifact                                                            |
| -------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `/pf-issue`    | Audit a tracker issue against the contracts and the code; validate the top options with subagents. No repo changes.       | The **issue audit** — a markdown report the user decides on          |
| `/pf-research` | Frame the change, gather what the frame needs; narrate what is and what should become. No repo changes.                  | The **research narrative** — an HTML page the user confirms          |
| `/pf-spec`     | Write the approved research into the product contracts; open the **epic PR**; iterate until it matches theory.            | Contract deltas in the epic PR + the **spec narrative**              |
| `/pf-build`    | Implement the contract spec in real code via `tdd`-chain sub-task PRs merged into the epic branch; prove it live.      | The **demo** — walkthrough + discrepancy report vs the contract spec |

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
- **The user's language** — everything else the cycle writes, because the user is its only reader: chat, `/pf-issue`'s `issue.md`, `/pf-research`'s `research.html`, `/pf-spec`'s `spec.html`. That language is the one the user is addressed in: what their instructions name for replies, else the one they write in.

Nothing is translated. Each command reads its predecessor's file in the language it was written in, and writes contract deltas, PR text, task files and prompts as English from the start. When a narrative has to go to the team, build an English copy then, as a one-off.

Identifiers, paths, commands, contract terms, error text and code stay in English inside any page, whatever the page's language.

## Artifact storage

Every cycle's narratives live in `~/.claude/artifacts/<id>/` — never committed to the product repo. `<id>` is a short kebab topic slug by default; when a Linear epic or issue exists (pre-existing, or created on explicit request), use its id instead and rename a slug-named directory to it.

- Canonical sources: `issue.md` (with its `issue-source.md`, `context.md`, `candidates.md` working files), the filled pages `research.html`, `spec.html` and `demo.html` with their frames under `frames/`, and `/pf-build`'s sub-task files under `tasks/`. **The filled page is the canonical source**: a later command reads it, and each feedback round edits it (pf-cycle-narratives → Narrative HTML mechanics).
- Built pages, written by `assemble.py` and never edited: `build/research.html`, `build/spec.html`, `build/demo.html`, plus `build/<name>.artifact.html` for Artifact publishing.
- **Which file is the source.** A `research.html` or `spec.html` that carries the `<!-- kit: head -->` marker is a filled page: read it, whatever else the directory holds. One without the marker is a built page from an older cycle: read that cycle's `research.md` or `spec.md`, or `divination.md` / `inscription.md` before 2026-08. A rerun in an older directory writes a filled page, which then wins.

## The frame

`/pf-research` and `/pf-issue` gather against a frame written before the first search: in the Frame block of `research.html` and at the top of `context.md` respectively. It has four parts:

- **The question** — the decision the step must settle: for `/pf-research`, the change the user brought and the choices that shape it; for `/pf-issue`, which fix the issue's claims call for.
- **The governing rule** — the contract lines that define the rule in dispute, read first and quoted with `file:line`: what a field means, who a rule protects, what it requires and of whom. The answer is as wide as that rule demands; cite the line behind each part of it.
- **Required evidence** — the claims the answer rests on, each to be settled with evidence.
- **Done when** — every required claim has a verdict and the question has an answer the evidence supports.

A neighbouring finding — another surface, an adjacent defect, a related smell — widens the frame only when it changes the answer: it refutes the answer, it shows the answer leaves the defect in place (a symmetric leak under the same rule), or it is a surface the answer itself alters. Widen by an edit to the frame that states the finding behind it. Every other finding gets one line in the step's out-of-scope list (`/pf-issue`'s «Рядом, но вне задачи», the research narrative's open questions) and the gather moves on.

## Environment preflight

Before the first piece of work that needs the live environment — a screenshot, a live request, a prod read, the demo — run one preflight, and fix what it finds before the long pass. Each item is one cheap command with a pass or fail signal; check the items the coming work needs.

- **Stack** — `bun run dev:wait` reports ready, `bun run dev:url` names the port you will drive, and that stack serves the branch under test. Dependencies are installed and the build outputs the flow loads exist, so a missing module or an unbuilt bundle fails here instead of mid-flow.
- **Roles** — the auth for each role the work acts as answers (`dev:token` for a seeded user), and any prod or cloud access the work reads answers one cheap call (for AWS, `aws sts get-caller-identity`).
- **Browser and capture** — the Playwright MCP opens the `dev:url` page, and one `browser_take_screenshot` to the real target path leaves a file you can see on disk.
- **Async work** — for each background job the flow waits on, the explicit trigger (an API call or a command) and when the job should start. When that time passes, check the job's state once; a job that is neither queued nor running gets the explicit trigger.

An item you cannot fix goes to the user as a blocker, with the failing command and its output, before the long pass starts. Work that does not depend on it continues.

## Dispatching subagents

Every subagent that researches or checks — a gather lane, an audit, a validator, a re-check — works from a bounded brief and ends when each of its claims has a verdict. `/pf-build`'s implementation sessions follow that skill's own rules.

- **Claims.** List the claims to confirm or refute, each with the `file:line` or source it rests on. When the question is open, name the surface and the questions the agent must answer. When the question is completeness ("every entry point of X"), measure the inventory first: one grep or throwaway script produces the list, and each item on it becomes a claim.
- **Settled evidence.** Pass the facts already verified (the artifact directory's `gather/*.md`, `context.md`, an earlier round's report) as settled; the agent cites them as given. A fact the user has questioned is a claim again. The claims are the agent's whole scope.
- **A budget.** About 30 tool calls for a check, about 60 for a gather lane. The agent reads each file range once and works from its notes after. It stops and reports at the budget, or after ten calls in a row that add no verdict and no new cited fact: findings so far, every unreached claim as UNVERIFIED, and the narrower scope that would settle it.
- **A verdict per claim.** Confirmed, refuted, or UNVERIFIED, each with its evidence line.

A re-check targets the claims that came back refuted, disputed, or UNVERIFIED, plus every claim the user questions; every other verdict goes in as settled. Split parallel agents by claim, so each claim has one owner. Resume an UNVERIFIED claim with a narrower brief, or check it yourself. A completion that reports usage far over budget points at the brief: narrow it before the next dispatch.

## Deferred deltas

A **deferred delta** is a contract change that needs working code the epic PR can't yet carry — a gate would fail on it. Don't stub or fake it: `/pf-spec` records it in the spec narrative as the artifact file plus the precise entries/fields/values expected in its diff; `/pf-build` carries each one into the sub-task that implements it and verifies that diff at review.

## Missing-prior analysis — feedback handling

Every round of user feedback on any artifact of the cycle gets analyzed item by item, not just applied:

1. **Under-specified instruction** — the narrative/spec/instruction simply didn't say. Fine: apply the feedback, note it in the iteration log.
2. **Missing prior** — the repo context should already have told the AI: a standing convention, product fact, constraint, or taste the user has stated before or plainly holds as policy. Apply the feedback **and** write the prior into its single right home in the repository — repo `CLAUDE.md` only if every session needs it; otherwise the area `README.md`, the contract overview, or a skill. Ship it in the currently open PR when one exists, else a small standalone PR.

The test: *would a fresh session with no chat history have gotten this right from the repo alone?* If no, and the user expects it as standing policy, it is a missing prior. Log every item in the narrative's iteration ledger: feedback → classification → where the prior landed (or why none was needed).
