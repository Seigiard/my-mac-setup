# Render kit for HTML pages

Reached from `~/.claude/rules/artifacts.md` for any HTML page or Claude Artifact, and from the `explain-diff-html` skill, whose template is built on it.

Write semantic HTML and let the kit style it. Two libraries load from jsDelivr, both following `prefers-color-scheme`: Pico 2.1.1 styles every bare element (`hgroup`, `nav`, `article`, `details`, `blockquote`, `figure`, `table`, `kbd`, `mark`, `ins`, `del`, `progress`, `dialog`, forms), and speed-highlight 2.1.0 colours code blocks. The class vocabulary is Pico's table below plus the kit's own components; an element outside those carries no class.

## Assembling a page

A draft carries three markers and `python3 ~/.claude/shared/render-kit/assemble.py <draft> -o <page>` replaces them with the kit's files, so the page carries the kit inside itself and works from disk, by mail, or on a host:

- `<!-- kit: head -->` inside `<head>`, after `<title>`: `head.html`, with charset and viewport, the three stylesheet links, and a base layer of four rules with the reason for each (body font stated against host resets, a side gutter on `main.container`, a reading measure on `p` and `li`, code blocks in Pico's colours).
- `<!-- kit: components -->` right after it: `components.css` in a `<style>`.
- `<!-- kit: scripts -->` at the end of `<body>`: `scripts.html`, the highlighter loader.

A page's own rules, when it needs any, go in a `<style>` after the components marker and use Pico's variables (`--pico-primary`, `--pico-muted-color`, `--pico-muted-border-color`, `--pico-card-background-color`, `--pico-code-background-color`, `--pico-border-radius`, `--pico-spacing`) so both themes follow.

## Publishing as a Claude Artifact

Artifacts load scripts from a few CDNs and no external stylesheet. `python3 ~/.claude/shared/render-kit/inject-styles.py <page> -o <copy>` rewrites each `<link rel="stylesheet">` into a `<style>` with the fetched CSS, media attributes kept, and exits 1 naming any sheet it could not fetch. Publish the copy; the original keeps its links. The Artifact host wraps the file in its own skeleton, so a page may start at `<title>` without `<html>`, `<head>` or `<body>`; the head snippet's `<meta charset>` still matters when the same file is opened from disk.

## The kit's components

| Class | On | Markup | Effect |
|---|---|---|---|
| `rows` | `dl` | `<dl class="rows"><dt>Label</dt><dd>…</dd>…</dl>`, inside an `<article>` when it needs a title band | two-column grid, labels in the accent colour, one column on phones |
| (none) | `figure` | `<figure><img …><figcaption>… <small>source</small></figcaption></figure>`; two side by side inside `<div class="grid">` | a card with the caption under a rule, numbered «Кадр N.» by a CSS counter |
| `checklist` | `ul` | `<li><label><input type="checkbox"> …</label></li>` | items the reader can tick, no bullets |
| `toc` | `nav` | `<nav class="toc"><ul><li><a href="#…">…</a></li></ul></nav>` | a row of section links, hidden in print |
| `mermaid` | `pre` | `<pre class="mermaid">sequenceDiagram …</pre>` plus the Mermaid loader script | a sequence or state diagram |
| `flow` | `div` | `<div class="flow"><div class="box"><b>Label</b><code>value</code></div><div class="arrow">→</div>…</div>` | data flow with example data: boxes in a row, stacked on phones |
| `ui` | `div` | `<div class="ui"><div class="bar">title</div><div class="row"><span>…</span><span class="btn new">…</span></div></div>` | a labelled sketch of a screen, the fallback when no frame exists |

## Pico's classes, all of them

| Class | On | Effect |
|---|---|---|
| `container` | `main` | centred page column |
| `container-fluid` | `main` | full-width column |
| `grid` | `div` | equal columns, one column on phones |
| `overflow-auto` | `div` or `figure` | scroll a wide table or diagram |
| `striped` | `table` | zebra rows |
| `secondary`, `contrast`, `outline` | `button`, `a`, `input[type=submit]` | muted, high-contrast, hollow variants |
| `dropdown` | `details` | a menu opened by `summary` |
| `modal-is-open`, `modal-is-opening`, `modal-is-closing` | `html` | scroll lock and transitions for `dialog` |

Attributes Pico reacts to: `data-tooltip` (+ `data-placement`) on any element, `aria-busy="true"` for a spinner, `role="group"` on `fieldset` or `div` to join controls, `role="button"` on `summary` or `a`, `aria-label="breadcrumb"` on `nav`, `name` on sibling `details` for an exclusive accordion, `rel="prev"` on a close button in a `dialog` header, `data-theme="light|dark"` on `html` to force a theme.

## Code blocks

A code block is `<div class="shj-lang-<lang>">` holding the text with `<`, `>` and `&` escaped; the highlighter keeps whitespace and wraps the lines itself. `diff` colours lines starting with `+` or `-` green and red and mutes `@@` lines and `---`/`+++` headers, so a sketch of a change needs no spans of its own. Real code takes `ts`, `js`, `bash`, `sql`, `yaml`, `json`, `py`, `go`, `rs`, `html`, `css`, `md`, or `plain`. Inline code stays `<code>`, styled by Pico. Markdown rendered at runtime (marked) yields `<pre><code class="language-x">`; convert those to `shj-lang-x` blocks before `highlightAll()`, mapping unknown languages to `plain`.

## Pico components by markup

| Component | Markup | Typical use |
|---|---|---|
| Accordion | `<details><summary>…</summary>…</details>`; `name="x"` on siblings makes them exclusive; `<summary role="button">` renders as a button | long material collapsed by default |
| Card | `<article><header>…</header>…<footer>…</footer></article>` | a block with a title band |
| Tooltip | `<dfn data-tooltip="…">term</dfn>` | a term defined at first use |
| Nav | `<nav><ul><li><a>…</a></li></ul></nav>`, one `<ul>` per side; `<nav aria-label="breadcrumb">` for a path | table of contents, section links |
| Progress | `<progress value="3" max="5">`; no `value` means indeterminate | a stage of a rollout |
| Loading | `<span aria-busy="true">…</span>` | a loading state |
| Group | `<fieldset role="group"><input><button></fieldset>` | a search bar or button row |
| Dropdown | `<details class="dropdown"><summary>…</summary><ul><li>…</li></ul></details>` | a menu |
| Modal | `<dialog open><article>…</article></dialog>` | a dialog shown static |
| Callout | `<blockquote>…</blockquote>` | a rule or edge case set apart from the prose |
| Title | `<hgroup><h1>…</h1><p>…</p></hgroup>` | a title with its meta line |
| Table | `<div class="overflow-auto"><table class="striped">…</table></div>` | a wide or long table |
