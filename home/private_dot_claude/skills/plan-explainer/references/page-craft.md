# Page craft

Mechanics for building, publishing, and actually checking the page.

## Page skeleton

The Artifact tool wraps the file in `<!doctype html><head>…</head><body>`, so when publishing through it, write page content only — no `<html>`, `<head>`, or `<body>` tags. When the file is the deliverable itself, open with `<!doctype html>` and wrap the content properly so the file stands alone. Either way start with a `<title>`: a short noun phrase, not a summary.

Define the full light palette on bare `:root`, then redefine the same tokens twice — once under `prefers-color-scheme: dark` guarded with `:root:not([data-theme="light"])`, once under `:root[data-theme="dark"]`. A colour whose only definition sits inside a media block breaks one of the three theme states. Give `body` an explicit token background.

```html
<title>Sidebar Git Status</title>
<style>
  :root{
    --bg:#f6f5f2; --ink:#14171c; --muted:#666e7a; --line:#dedad2; --card:#fff;
    --accent:#0d7c72; --accent-soft:#d8f0ed; --warn:#a35a06; --warn-soft:#fdeccd;
    --bad:#b2201c; --bad-soft:#fbdedd; --good:#1a7a36; --good-soft:#d9f2df;
    --term-bg:#101318; --term-ink:#e7edf3; --term-dim:#7f8b99; --term-line:#262c35;
  }
  @media (prefers-color-scheme: dark){
    :root:not([data-theme="light"]){ /* same token names, dark values */ }
  }
  :root[data-theme="dark"]{ /* same token names, dark values */ }

  *{box-sizing:border-box}
  body{background:var(--bg);color:var(--ink);margin:0;
       font:16px/1.5 ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif;
       padding:clamp(20px,4vw,56px) clamp(16px,4vw,40px) 96px}
  .wrap{max-width:1000px;margin:0 auto}
  section{margin-top:clamp(56px,9vw,110px)}
</style>
```

Wrap every block of page content in a `<section id="…">`, the opening one included. The capture script walks `<section>` elements and names each file after its id, falling back to `section-1`, `section-2` for an unnamed one. Content outside a section never reaches a screenshot.

Typography carries the "few words" feel: headings at `clamp(25px,4.4vw,40px)`, one lead sentence per section at `clamp(17px,2.2vw,20px)` in `--muted`, capped near `52ch`.

## Class names to keep consistent

Reuse one vocabulary across sections so the page stays editable: `.card`, `.grid .g2 .g3`, `.tag` with `.t-acc/.t-good/.t-warn/.t-bad`, `.mono`, `.scroll`, `.big`, `.say`. Section-specific sets — `.route/.station/.switchbox/.branch`, `.pair/.no-block/.yes-block`, `.board/.cell`, `.paper` — belong to their sections.

**Collision trap:** a short generic class such as `.step`, `.item`, or `.row` defined for one section will silently restyle another section's element with the same name. Before adding a class, grep the file for it. When in doubt, prefix: `.stn` beat `.step` for exactly this reason.

## Wide content

Keep the page body's width fixed: route every wide table, scoreboard or diagram into its own `<div class="scroll">` with `overflow-x:auto`, where the inner grid may set `min-width`.

## Mermaid

Artifacts render mermaid natively — no library, no script tag. Use a `<pre class="mermaid">` block in HTML. Keep labels short. Wrap it in a container with `overflow-x:auto` and give the svg `max-width:100%;height:auto`.

## Delivering the page

### With the Artifact tool (Claude Code)

Publish with `file_path`, a one-sentence `description`, and a `favicon` of one or two emoji. Keep the favicon and title stable across redeploys — users find the tab by its icon.

**Republishing the same `file_path` keeps the URL.** A different path creates a second artifact and orphans the link. To update an artifact from an earlier session, pass its URL as `url`.

### Without it (OpenCode and other hosts)

There is no publish step: the HTML file is the deliverable. Write it where it will still exist tomorrow, not in a scratch directory.

- When the plan lives in a repository, put the page beside it: `docs/explainers/<date>-<slug>-explainer.html`. That keeps the page reviewable in the same diff as the plan.
- Otherwise write to a path the user names, and say the full absolute path in the report.
- Rewrite the same path on later passes so an existing link or bookmark keeps working.

Three actions get confused here; keep them apart:

| Action | When |
|---|---|
| Open headlessly through `agent-browser` | Always, for verification |
| Launch the user's visible browser | Only when the user asks for it |
| Put a copyable `open "<absolute-path>"` line in the report | Always, whenever there is no Artifact URL |

Keep the page self-contained in both modes — inline every style and script, embed images as `data:` URIs. A local page may load remote assets, but then it breaks the moment it is moved, mailed, or published later.

## Verifying the page

The published page renders inside an iframe on claude.ai, where browser tools cannot scroll it or run JavaScript. Verify the local file instead — the wrapper adds nothing that changes layout.

One command captures the whole page:

```bash
bash ~/.claude/skills/plan-explainer/scripts/capture-sections.sh <html-file> <out-dir>
```

Read every PNG it lists — the script removes the repetition, never the looking. Its header comment carries the rest of the contract: what it prints, what makes it exit nonzero, and the fact that a section taller than four viewports is captured only that far down.

### What has to be checked

| Check | Standing |
|---|---|
| Every section captured in the default theme | required |
| Manifest line count reconciled against the page's `<section>` count | required |
| Every capture read | required |
| Page-level horizontal overflow | required (the script prints it) |
| Sections changed after review recaptured and reread | required |
| Browser console output | recommended |
| A dark-theme sample | required when the page ships a dark theme |
| Narrow screens | report as unverified — `agent-browser` has no resize command |

That table is the stopping condition. Checks beyond it are optional.

### Driving agent-browser by hand

When the script cannot run, the same loop by hand is `open`, then per section `eval` with `scrollIntoView`, then `screenshot`:

```bash
npx -y agent-browser open "file:///abs/path/page.html"
npx -y agent-browser eval "(() => { document.querySelector('#route').scrollIntoView({block:'center'}); return 'ok'; })()"
npx -y agent-browser screenshot "/abs/path/shot-route.png"
npx -y agent-browser close
```

Two traps that cost real time:

- **One javascript scope is shared by every `eval` in a session.** A second `const el` fails with "Identifier 'el' has already been declared" and the call returns nothing, which reads as a missing element rather than a scope error. Wrap each body in an IIFE, as above.
- **Scroll, then capture.** `screenshot` takes a viewport frame; passing a selector to it captures whatever the viewport currently holds, which for an off-screen section is blank background — evidence that looks real and is not.

Also: pass `screenshot` an absolute path, or the file lands somewhere unpredictable.

## Reporting

Split the claims:

- **Verified:** rendered locally and read the screenshots; which sections.
- **Not verified:** narrow screens, dark theme, anything skipped.

Call a section verified once its screenshot has been read — an error-free write says nothing about how it renders.
