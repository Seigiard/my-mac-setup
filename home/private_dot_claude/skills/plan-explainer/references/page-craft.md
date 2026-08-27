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

Typography carries the "few words" feel: headings at `clamp(25px,4.4vw,40px)`, one lead sentence per section at `clamp(17px,2.2vw,20px)` in `--muted`, capped near `52ch`.

## Class names to keep consistent

Reuse one vocabulary across sections so the page stays editable: `.card`, `.grid .g2 .g3`, `.tag` with `.t-acc/.t-good/.t-warn/.t-bad`, `.mono`, `.scroll`, `.big`, `.say`. Section-specific sets — `.route/.station/.switchbox/.branch`, `.pair/.no-block/.yes-block`, `.board/.cell`, `.paper` — belong to their sections.

**Collision trap:** a short generic class such as `.step`, `.item`, or `.row` defined for one section will silently restyle another section's element with the same name. Before adding a class, grep the file for it. When in doubt, prefix: `.stn` beat `.step` for exactly this reason.

## Wide content

Tables, boards, and diagrams go inside `<div class="scroll">` with `overflow-x:auto`, and the inner grid may set `min-width`. The page body must never scroll horizontally.

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
- Offer to open it: `open <path>` on macOS.
- Rewrite the same path on later passes so an existing link or bookmark keeps working.

Keep the page self-contained in both modes — inline every style and script, embed images as `data:` URIs. A local page may load remote assets, but then it breaks the moment it is moved, mailed, or published later.

## Verifying the page

The published page renders inside an iframe on claude.ai. Browser-automation tools cannot scroll it or run JavaScript in it, so **verify the local file instead** — the wrapper adds nothing that changes layout.

```bash
D=/abs/path/to/scratchpad
npx -y agent-browser open "file://$D/page.html"
npx -y agent-browser eval "document.querySelector('.route').scrollIntoView({block:'center'}); 'ok'"
npx -y agent-browser screenshot "$D/shot-route.png"
npx -y agent-browser close
```

Then read each PNG and look at it. Checking that a file exists is not checking that it renders.

Details that matter:

- **Pass an absolute path to `screenshot`.** A relative path silently lands somewhere else.
- `agent-browser` has **no `resize` command**, so narrow-screen layout cannot be verified this way. Report it as unverified rather than claiming it works.
- `eval` plus `scrollIntoView` is the reliable way to reach a section; whole-page screenshots of a long page are unreadable.
- A quick overflow check: `document.scrollingElement.scrollWidth <= document.scrollingElement.clientWidth`.

## Reporting

Name each section and the plan content behind it. Then split the claims:

- **Checked:** rendered locally and read the screenshots; which sections.
- **Not checked:** narrow screens, dark theme, anything skipped.

Never report a section as verified because the HTML was written without an error.
