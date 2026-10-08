# The pf cycle — building and publishing narrative pages

Not a command. The page mechanics for `/pf-research`, `/pf-spec` and `/pf-build`: screenshots, the narrative HTML, rendered contract diffs, publishing. The rest of the shared mechanics (artifact directory, naming, language, Linear) are in `~/.claude/shared/pf-cycle.md`; read that first.

## Screenshot mechanics

Every capture in the cycle — `/pf-research`'s "before" shots, `/pf-spec`'s story renders, `/pf-build`'s live demo walkthrough — follows these rules:

- **Screenshots are real renders, never hand-mocked.** Stories: `bun run vrt:capture <story files>` → pixel-perfect PNGs at `__vrt__/<story path>/<Export>.png` (plays run before capture, so a story lands in its post-play state). Marketing/static pages: throwaway static server + `console/node_modules/.bin/playwright screenshot --viewport-size=1440,1600 <url> <out.png>`. Screens package: `cd engine/screens && bun run vrt:capture`.
- **The running app: validate and capture in ONE pass.** Drive it with the Playwright MCP (`browser_navigate`, `browser_click`, `browser_type`, `browser_fill_form`) and capture with `browser_take_screenshot` given `filename` and `type: "jpeg"` — it writes the frame to disk, so the drive that proves the behavior is also the drive that produces the images. Never validate with one tool and then re-drive the whole flow with a script just to save files. A relative `filename` resolves against the workspace root: capture into the repo's gitignored `.logs/`, copy out after. Use Claude in Chrome only when the flow needs the user's signed-in browser; its screenshots land in context and never on disk. The capture result already shows you the frame; to look at a frame again, read its downscaled JPEG (the `sips` line under Narrative HTML mechanics), never the full-size source. Repo-side helpers (`dev:wait`, `dev:url`, `dev:token`, `seed:demo-job`, `?noAutoLogin`, demo test-ids) are documented in `internal-dev-doc/browser-automation.md` — read it before driving the app.
- **Resolve the port, never assume it.** Multiple app stacks run at once (one per worktree) on auto-discovered ports, so a hardcoded `localhost:9000` usually points at another branch's app and demos the wrong code without erroring. Build every URL from `bun run dev:url [path]`.

## Narrative HTML mechanics

### House style — the default look for every narrative page

Start here rather than inventing a look per page; deviate only when a specific page has a reason to.

**Treatment: utilitarian, not editorial.** These pages are read for their findings, so the craft goes into information design — polished type and spacing, no flashy hero, no decorative flourish. A reader should be able to scan the page and come away with the verdicts alone.

**Palette: tokens, both themes, neutrals biased toward the accent.** Define the whole palette as custom properties on `:root`; redefine only the tokens under `@media (prefers-color-scheme: dark)`, then again under `:root[data-theme="dark"]` / `[data-theme="light"]` so the viewer's toggle wins in both directions. Style components through tokens, never inside the media query. Semantic colour (good / warning / critical) is a separate axis from the accent and carries meaning — never decoration. Pick an accent from the subject's own world; avoid the AI-default cream+serif+terracotta and purple-gradient looks.

**Type: mono-forward for data, sans for prose.** All figures, labels, eyebrows and table cells in `ui-monospace` with `font-variant-numeric: tabular-nums` so columns align; headings and running prose in a tight system sans; body text capped near 70ch. Uppercase mono labels with `.1em`–`.16em` letter-spacing are the section and eyebrow device. No webfont URLs — the CSP blocks them and you get a silent fallback.

**Structure: every claim carries its verdict and its provenance.** The repeating unit is a bordered card: a heading, a verdict chip (e.g. corroborates / contradicts / new capability / overturns an assumption), 1–3 sentences, an optional data table, and a final `sources` line naming the overlap the claim rests on. Severity lives in the chip and the heading colour — **never a thick coloured left rail on the card**, which is the single most recognisable AI-generated-UI tell. Stat rows (`label / big number / one-line note`) carry the headline figures; tables get `overflow-x: auto` on their own container so the page never scrolls sideways.

**Close with decisions and open questions, separated.** Each decision states the choice made and why; each open question is one the reader is being asked to answer. Both as short blocks with a mono uppercase label. Then a footer naming the exact sources and the run/commit the figures came from, so any number can be traced.

**Numbers are the argument.** Every figure recomputed from raw sources rather than quoted from a previous artifact, and stated with its population (`156 of 245 SKUs`), never bare. Where a claim rests on an assumption, say so in the same sentence.

### Page structure

Self-contained HTML, the flow in product order, one section per step: title, status badge, a 1–3 sentence narrative, the screenshot, and the Storybook story link + component file paths behind it (when they exist). Top of page: a one-line model summary and a dated iteration log. **Every screenshot must be clickable to expand**: wrap each `<img>` in a dependency-free lightbox (click → fullscreen overlay at natural size, click anywhere or Escape to close, `cursor: zoom-in` on the thumbnail) — inline screenshots are downscaled and reviewers need the pixels.

Mechanics that keep it cheap to update:

- **A generator script, not a hand-edited page.** Keep a `build.ts` next to the images: a step-manifest array (title, narrative, badge, img, story id, file paths) + a template that inlines images as base64. Downscale first (`sips -s format jpeg -s formatOptions 82 --resampleWidth 1100`) so 15+ frames stay ≈1 MB. Updating = re-capture changed frames, edit the manifest, `bun build.ts`, republish.
- **Standalone-proof.** Start with `<meta charset="utf-8">` (raw-file viewers garble punctuation without it); inline everything (a shared page can't load external hosts); link stories at the default `http://localhost:6006` with a "port may differ — `bun run dev:ports`" note; state the branch so pointers resolve.

## Rendering contract diffs

Render contract deltas, don't paste them: `bun run contracts:diff <refA> <refB> [--contract <name>]` (or the artifact diffs off the epic branch) rendered into an HTML section — per contract: added / changed / removed entries and the computed impact label. The user approves the contract surface visually, alongside the screenshots of what it becomes.

## Publishing

- Publish `research.html` and `spec.html` with the Artifact tool and **republish the same file path every iteration** so the shared link stays current; label versions. The raw file doubles as a Slack/Linear attachment when a snapshot is wanted. The demo is the exception: it publishes to the VRT host the team can already see (`/pf-build` → The demo).
- The built pages get shared beyond this chat, so their visible text — `<title>`, headings, badges, prose — follows **Naming on public surfaces** and **Language** above.
