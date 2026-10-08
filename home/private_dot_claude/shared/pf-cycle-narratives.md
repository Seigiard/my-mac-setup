# The pf cycle — building and publishing narrative pages

Not a command. The page mechanics for `/pf-research`, `/pf-spec` and `/pf-build`: screenshots, the narrative HTML, rendered contract diffs, publishing. The rest of the shared mechanics (artifact directory, naming, language, Linear) are in `~/.claude/shared/pf-cycle.md`; read that first.

## Screenshot mechanics

Every capture in the cycle — `/pf-research`'s "before" shots, `/pf-spec`'s story renders, `/pf-build`'s live demo walkthrough — follows these rules:

- **Screenshots are real renders, never hand-mocked.** Stories: `bun run vrt:capture <story files>` → pixel-perfect PNGs at `__vrt__/<story path>/<Export>.png` (plays run before capture, so a story lands in its post-play state). Marketing/static pages: throwaway static server + `console/node_modules/.bin/playwright screenshot --viewport-size=1440,1600 <url> <out.png>`. Screens package: `cd engine/screens && bun run vrt:capture`.
- **The running app: validate and capture in ONE pass.** Run pf-cycle → Environment preflight first, then drive it with the Playwright MCP (`browser_navigate`, `browser_click`, `browser_type`, `browser_fill_form`) and capture with `browser_take_screenshot` given `filename` and `type: "jpeg"` — it writes the frame to disk, so the drive that proves the behavior is also the drive that produces the images. Never validate with one tool and then re-drive the whole flow with a script just to save files. A relative `filename` resolves against the workspace root: capture into the repo's gitignored `.logs/`, copy out after. Use Claude in Chrome only when the flow needs the user's signed-in browser; its screenshots land in context and never on disk. The capture result already shows you the frame; to look at a frame again, read its downscaled JPEG in `frames/` (Narrative HTML mechanics). Repo-side helpers (`dev:wait`, `dev:url`, `dev:token`, `seed:demo-job`, `?noAutoLogin`, demo test-ids) are documented in `internal-dev-doc/browser-automation.md` — read it before driving the app.
- **Sketches are captured too.** A screen that does not exist yet still becomes a frame. Pick the cheapest real render: a Storybook story, a temporary edit in the running app, or a throwaway HTML wireframe in the artifact directory's `sketches/`, served by the throwaway static server and captured with Playwright. Undo a temporary edit after the capture, and keep it out of every commit. The caption opens with "Sketch" in the page language, so no reader takes it for the product.
- **Resolve the port, never assume it.** Multiple app stacks run at once (one per worktree) on auto-discovered ports, so a hardcoded `localhost:9000` usually points at another branch's app and demos the wrong code without erroring. Build every URL from `bun run dev:url [path]`.

## Narrative HTML mechanics

A narrative page is a template from `~/.claude/shared/pf-cycle-pages/` filled in place, on the render kit (`~/.claude/shared/render-kit.md`). The template owns structure, the kit owns styling, and the filled page is the step's canonical source.

- **Start from the template.** Copy `research.html`, `spec.html` or `demo.html` from `~/.claude/shared/pf-cycle-pages/` into the artifact directory and fill each `<!-- slot: … -->` in place. Keep the three `<!-- kit: … -->` markers. Translate the headings and labels into the page language once, keeping the ids. Each element a slot names (frame, claim card, chip, contract card, Mermaid diagram, checklist, iteration table) has a working example in `~/.claude/shared/render-kit/gallery.html`; copy its markup from there. A page carries only the kit's classes, with no `<style>` of its own.
- **Frames by path.** Downscale each capture into `frames/` beside the page (`sips -s format jpeg -s formatOptions 82 --resampleWidth 1100 <in.png> --out frames/<name>.jpg`, so 15 or more frames stay near 1 MB) and point the `<img src>` at that relative path. The source stays small enough to read and edit. Every frame opens at natural size on click, which the kit provides.
- **Build.** `python3 ~/.claude/shared/render-kit/assemble.py <name>.html -o build/<name>.html` inlines the kit and every frame, so the built page opens from disk, by mail, or on a host. It exits 1 and names any frame it cannot find.
- **Each feedback round** is one edit of the source and one `assemble.py` run, then a republish.

### Content rules

- **Utilitarian, not editorial.** A reader scans the page and comes away with the verdicts alone.
- **Every claim carries its verdict and its provenance.** A claim card: a heading, a verdict chip (corroborates, contradicts, new capability, overturns an assumption), 1–3 sentences, an optional table, and a `Sources:` footer naming what the claim rests on. Chip colour carries meaning: `good`, `bad`, `new`, or bare.
- **Numbers are the argument.** Recompute every figure from raw sources rather than quote a previous artifact, and state it with its population (`156 of 245 SKUs`). Where a claim rests on an assumption, say so in the same sentence.
- **Decisions apart from open questions.** Each decision states the choice and why; each open question is one the reader answers. A closing footer names the sources and the run or commit behind the figures.
- **Diagrams are Mermaid.** A flow between screens, data changing shape (each node carries an example value), a sequence or a state: a `<pre class="mermaid">` block. A screen is a frame, never a diagram.
- **Flow sections in product order:** a heading with its status in `<small>`, a 1–3 sentence narrative, the frame, and the story link and component paths in the caption's `<small>`, when they exist. Link stories at `http://localhost:6006` with a "port may differ — `bun run dev:ports`" note, and state the branch so pointers resolve.

## Rendering contract diffs

Render contract deltas, don't paste them: `bun run contracts:diff <refA> <refB> [--contract <name>]` (or the artifact diffs off the epic branch) rendered into the spec template's contract card — per contract: the diff as a `shj-lang-diff` block (added entries as `+` lines, removed as `-`) under the computed impact label. The user approves the contract surface visually, alongside the screenshots of what it becomes.

## Publishing

- Publish `build/research.html` and `build/spec.html` as a Claude Artifact through the copy `python3 ~/.claude/shared/render-kit/inject-styles.py build/<name>.html -o build/<name>.artifact.html` writes, because Artifacts block external stylesheets. **Republish the same file path every iteration** so the shared link stays current; label versions. The built page doubles as a Slack or Linear attachment when a snapshot is wanted. The demo is the exception: it publishes to the VRT host the team can already see (`/pf-build` → The demo).
- The built pages get shared beyond this chat, so their visible text (`<title>`, headings, chips, prose) follows **Naming on public surfaces** and **Language** in `pf-cycle.md`.
