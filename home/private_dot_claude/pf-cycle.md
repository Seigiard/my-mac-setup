# The pf cycle — shared mechanics for `/pf-research`, `/pf-spec`, `/pf-build`

Not a command. This file holds the mechanics shared by the three-step development cycle so each command file states them once. Each command tells you when to read this; follow it as part of that command.

## The cycle

| Step           | Does                                                                                                                      | Artifact                                                            |
| -------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `/pf-research` | Gather everything relevant; narrate what is and what should become. No repo changes.                                      | The **research narrative** — an HTML page the user confirms          |
| `/pf-spec`     | Write the approved research into the product contracts; open the **epic PR**; iterate until it matches theory.            | Contract deltas in the epic PR + the **spec narrative**              |
| `/pf-build`    | Implement the contract spec in real code via opencode sub-issue PRs auto-merged into the epic branch; prove it live.      | The **demo** — walkthrough + discrepancy report vs the contract spec |

**The epic PR lifecycle:** `/pf-spec` opens it (base `main`, contracts only, green) and it **stays open**. `/pf-build` merges implementation PRs into its branch, so it grows into the single big PR carrying contracts + code. The **user** reviews that final PR with the demo and merges it — the only merge to `main` in the whole cycle. Merging to main deploys to prod; the cycle deliberately batches that into one reviewed moment.

## Linear is opt-in — the cycle tracks itself in local artifacts

By default the cycle creates **nothing in Linear**: no epics, no sub-issues, no comments, no attachments. The artifact directory (below) is the tracker — research narrative, spec narrative, sub-task files, statuses all live there. Reading Linear as history (a pre-existing epic, prior issues) is always fine. Writing to Linear happens only when the user **explicitly asks** for Linear tracking, or a pre-existing epic makes an attachment obviously wanted and the user confirmed the flow uses it. When Linear is used, the naming rules below apply, and one CLI caveat: Linear's renderer mangles round-trip patches (strips `**bold**` around code spans, auto-links bare domains, rewrites bullets) — never patch rendered text; edit the local file, re-push the whole description, re-fetch to verify.

## Naming on public surfaces

The cycle's terms — research narrative, contract spec, epic PR, demo — are plain engineering language, safe anywhere. Two rules still bind everything a teammate, reviewer, or external tool reads (PR titles and bodies, commit messages, branch names, Linear epic/issue titles, descriptions, and comments, GitHub review comments, prompts to implementation agents, and all visible text of published HTML pages):

- **Name the product change, not the process stage.** The epic PR is named for what it will contain when it merges: "PRD-1234: Deliverable views" passes; "Contract spec for deliverable views" fails (see `/pf-spec` Step 2). The same applies to Linear epic titles and published page titles.
- **Don't narrate the cycle.** Public text describes the product and the change; which command of the cycle produced it is irrelevant to the reader and never appears.

## Artifact storage

Every cycle's narratives live in `~/.claude/artifacts/<id>/` — never committed to the product repo. `<id>` is a short kebab topic slug by default; when a Linear epic exists (pre-existing, or created on explicit request), use the epic id instead and rename a slug-named directory to it.

- Canonical sources: `research.md`, `spec.md`, `demo.md` (or a step-manifest in `build.ts`) plus captured images and `/pf-build`'s sub-task files under `tasks/`. **A later command reads the canonical source, not the built HTML** — keep sources current. Directories from cycles before 2026-08 may use the older names `divination.md` / `inscription.md` — read those when the new name is absent.
- Built pages: `research.html`, `spec.html`, `demo.html`.
- Publish each page with the Artifact tool and **republish the same file path every iteration** so the shared link stays current; label versions. The raw file doubles as a Slack/Linear attachment when a snapshot is wanted.
- The built pages get shared beyond this chat, so their visible text — `<title>`, headings, badges, prose — follows **Naming on public surfaces** above.

## Narrative HTML mechanics

### House style — the default look for every narrative page

Confirmed as standard 2026-07-24. Start here rather than inventing a look per page; deviate only when a specific page has a reason to.

**Treatment: utilitarian, not editorial.** These pages are read for their findings, so the craft goes into information design — polished type and spacing, no flashy hero, no decorative flourish. A reader should be able to scan the page and come away with the verdicts alone.

**Palette: tokens, both themes, neutrals biased toward the accent.** Define the whole palette as custom properties on `:root`; redefine only the tokens under `@media (prefers-color-scheme: dark)`, then again under `:root[data-theme="dark"]` / `[data-theme="light"]` so the viewer's toggle wins in both directions. Style components through tokens, never inside the media query. Semantic colour (good / warning / critical) is a separate axis from the accent and carries meaning — never decoration. Pick an accent from the subject's own world; avoid the AI-default cream+serif+terracotta and purple-gradient looks.

**Type: mono-forward for data, sans for prose.** All figures, labels, eyebrows and table cells in `ui-monospace` with `font-variant-numeric: tabular-nums` so columns align; headings and running prose in a tight system sans; body text capped near 70ch. Uppercase mono labels with `.1em`–`.16em` letter-spacing are the section and eyebrow device. No webfont URLs — the CSP blocks them and you get a silent fallback.

**Structure: every claim carries its verdict and its provenance.** The repeating unit is a bordered card: a heading, a verdict chip (e.g. corroborates / contradicts / new capability / overturns an assumption), 1–3 sentences, an optional data table, and a final `sources` line naming the overlap the claim rests on. Severity lives in the chip and the heading colour — **never a thick coloured left rail on the card**, which is the single most recognisable AI-generated-UI tell. Stat rows (`label / big number / one-line note`) carry the headline figures; tables get `overflow-x: auto` on their own container so the page never scrolls sideways.

**Close with decisions and open questions, separated.** Each decision states the choice made and why; each open question is one the reader is being asked to answer. Both as short blocks with a mono uppercase label. Then a footer naming the exact sources and the run/commit the figures came from, so any number can be traced.

**Numbers are the argument.** Every figure recomputed from raw sources rather than quoted from a previous artifact, and stated with its population (`156 of 245 SKUs`), never bare. Where a claim rests on an assumption, say so in the same sentence.

---

Self-contained HTML, the flow in product order, one section per step: title, status badge, a 1–3 sentence narrative, the screenshot, and the Storybook story link + component file paths behind it (when they exist). Top of page: a one-line model summary and a dated iteration log. **Every screenshot must be clickable to expand**: wrap each `<img>` in a dependency-free lightbox (click → fullscreen overlay at natural size, click anywhere or Escape to close, `cursor: zoom-in` on the thumbnail) — inline screenshots are downscaled and reviewers need the pixels.

Mechanics that keep it cheap to update:

- **Screenshots are real renders, never hand-mocked.** Stories: `bun run vrt:capture <story files>` → pixel-perfect PNGs at `__vrt__/<story path>/<Export>.png` (plays run before capture, so a story lands in its post-play state). Marketing/static pages: throwaway static server + `console/node_modules/.bin/playwright screenshot --viewport-size=1440,1600 <url> <out.png>`. Screens package: `cd engine/screens && bun run vrt:capture`.
- **The running app: validate and capture in ONE pass.** Drive it with a Chrome MCP and pass `filePath` to `take_screenshot` — it writes the PNG to disk, so the drive that proves the behavior is also the drive that produces the images. Never validate with one tool and then re-drive the whole flow with a script just to save files. `filePath` is sandboxed to workspace roots (capture into the repo's gitignored `.logs/`, copy out after); attach to the user's Chrome only via `isolatedContext` + `background: true`; and use `type_text` rather than `fill` on React forms, which ignore a DOM value set without the native setter. Repo-side helpers (`dev:wait`, `dev:url`, `dev:token`, `seed:demo-job`, `?noAutoLogin`, demo test-ids) are documented in `internal-dev-doc/browser-automation.md` — read it before driving the app.
- **Resolve the port, never assume it.** Multiple app stacks run at once (one per worktree) on auto-discovered ports, so a hardcoded `localhost:9000` usually points at another branch's app and demos the wrong code without erroring. Build every URL from `bun run dev:url [path]`.
- **Publish the demo where the team can already see it.** `bun run demo:publish <demo.html> --pr <N>` puts the page on the VRT host (`vrt.membrane-dev.com/platform/demos/…`), which is behind the team's Cloudflare Access SSO — one URL that works in chat, in the PR, and for anyone on the team, overwritten in place on republish. A Claude Artifact stays private until the user shares it, and an uploaded `.html` downloads rather than renders, so neither is the review surface. Still embed a few key frames inline (`bun linear-upload <png>` → `![caption](URL)`) and lead with what the demo proves.
- **A generator script, not a hand-edited page.** Keep a `build.ts` next to the images: a step-manifest array (title, narrative, badge, img, story id, file paths) + a template that inlines images as base64. Downscale first (`sips -s format jpeg -s formatOptions 82 --resampleWidth 1100`) so 15+ frames stay ≈1 MB. Updating = re-capture changed frames, edit the manifest, `bun build.ts`, republish.
- **Standalone-proof.** Start with `<meta charset="utf-8">` (raw-file viewers garble punctuation without it); inline everything (a shared page can't load external hosts); link stories at the default `http://localhost:6006` with a "port may differ — `bun run dev:ports`" note; state the branch so pointers resolve.

## Rendering contract diffs

Render contract deltas, don't paste them: `bun run contracts:diff <refA> <refB> [--contract <name>]` (or the artifact diffs off the epic branch) rendered into an HTML section — per contract: added / changed / removed entries and the computed impact label. The user approves the contract surface visually, alongside the screenshots of what it becomes.

## Missing-prior analysis — feedback handling

Every round of user feedback on any artifact of the cycle gets analyzed item by item, not just applied:

1. **Under-specified instruction** — the narrative/spec/instruction simply didn't say. Fine: apply the feedback, note it in the iteration log.
2. **Missing prior** — the repo context should already have told the AI: a standing convention, product fact, constraint, or taste the user has stated before or plainly holds as policy. Apply the feedback **and** write the prior into its single right home in the repository — repo `CLAUDE.md` only if every session needs it; otherwise the area `README.md`, the contract overview, or a skill. Ship it in the currently open PR when one exists, else a small standalone PR.

The test: *would a fresh session with no chat history have gotten this right from the repo alone?* If no, and the user expects it as standing policy, it is a missing prior. Log every item in the narrative's iteration ledger: feedback → classification → where the prior landed (or why none was needed).
