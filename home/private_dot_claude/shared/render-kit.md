# Render kit for HTML pages

Reached from `~/.claude/rules/artifacts.md` for any HTML page or Claude Artifact, from the `explain-diff-html` skill, and from the pf cycle's page templates in `~/.claude/shared/pf-cycle-pages/`, all built on it. `render-kit/gallery.html` shows, in working markup, every element a pf narrative page uses; assemble it to see the kit in both themes.

Write bare semantic HTML and let the kit style it. The kit is one base layer on CSS variables; page markup carries two classes, `language-x` on code and `mermaid` on a diagram, and every other element is styled by its tag. Two libraries load from jsDelivr as scripts: speed-highlight 2.1.0 colours code, and Mermaid draws diagrams.

## Assembling a page

A draft carries three markers and `python3 ~/.claude/shared/render-kit/assemble.py <draft> -o <page>` replaces them with the kit's files, so the page carries the kit inside itself and works from disk, by mail, or on a host:

- `<!-- kit: head -->` inside `<head>`, after `<title>`: `head.html`, with charset and viewport and the base layer: the colour tokens, the type, the page shell and every bare-element rule, each with the reason for it.
- `<!-- kit: components -->` right after it: `components.css` in a `<style>`: frames and the lightbox, code colours, the Mermaid block, the term bubble, print rules.
- `<!-- kit: scripts -->` at the end of `<body>`: `scripts.html`: the highlighter loader, the Mermaid loader, the term upgrade, the contents fallback, the frame lightbox.

An `<img src>` that names a local file, relative to the draft, becomes a data URI, so a draft keeps its frames as files and stays small enough to read and edit. Remote and `data:` sources and markup inside comments stay as written. A missing kit file or image stops the run with exit status 1.

A page's own rules, when it needs any, go in a `<style>` after the components marker and use the kit's variables (`--bg`, `--surface`, `--tint`, `--fg`, `--muted`, `--line`, `--accent`, `--good`, `--bad`, `--code-bg`, `--radius`) so both themes follow.

## Colour and type

`head.html` holds the tokens, each with its Harmony step (github.com/evilmartians/harmony 1.4.0, OKLCH, equal APCA contrast per step across hues) and its reason. Take a colour for a page's own rule from those variables, so both themes follow; the theme is `color-scheme`, set by the system and overridden by a host's `data-theme="light|dark"` on `html`. Type is the system fonts of modernfontstacks.com, so nothing downloads.

## Publishing as a Claude Artifact

Artifacts allow scripts from a few CDNs and block external stylesheets. The kit has none, so publish the assembled page as it is. The Artifact host wraps the file in its own skeleton, so a page may start at `<title>` without `<html>`, `<head>` or `<body>`; the head snippet's `<meta charset>` still matters when the same file is opened from disk. The host draws `pre.mermaid` itself, with Mermaid's default theme, which the page's CSS recolours.

## The vocabulary

| Element | Markup | Effect |
|---|---|---|
| `main`, `nav` | `<main lang="en">…</main>`; `<nav aria-label="Contents"><ul><li><a href="#…">…</a></li></ul></nav>` right after the `hgroup` | text on the left, the contents on the right, sticky, with the current section lit; on a phone or a window under 936 px a row of pills above the text. Hidden in print |
| `hgroup` | `<hgroup><h1>…</h1><p>meta</p></hgroup>` | the page title and its meta line, over a rule |
| `dl` | `<dl><dt>Label</dt><dd>…</dd></dl>`, inside an `<article>` when it needs a title band | two-column grid, labels in the accent colour, one column on phones |
| `article` | `<article><header>…</header>…<footer>…</footer></article>` | a soft-filled card; `header` and `footer` sit under and over a rule |
| `figure` | `<figure><img …><figcaption>… <small>source</small></figcaption></figure>`; two to compare sit in a bare `<div>` | a bare frame with a muted caption numbered by a CSS counter whose label follows the nearest `lang` ("Frame N.", `ru`: «Кадр N.»; another language adds its own `:lang()` rule in the page's `<style>`); a tall frame stops at three quarters of the screen height; a click opens the frame at natural size, and a click or Escape closes it |
| `ins`, `del`, `mark`, `small` | `<ins>corroborates</ins>`, `<del>contradicts</del>`, `<mark>new</mark>`, `<small>neutral</small>` | a label whose colour carries a verdict: good, bad, accent, muted. Beside a heading text it is small uppercase text; in an `article` header or a table cell it is a pill |
| `table` | `<table>…</table>` | rows alternate a fill; a wide table scrolls inside itself |
| `details` | `<details><summary>…</summary>…</details>` | a collapsed block; the summary is a fill button |
| `blockquote` | `<blockquote>…</blockquote>` | a rule or edge case set apart from the prose, behind an accent line |
| `ul` with a checkbox | `<li><label><input type="checkbox"> …</label></li>` | items the reader can tick, no bullets |
| `dfn` | `<dfn title="definition">term</dfn>` | a term defined at first use: dotted underline and a bubble on hover or focus, anchored to the term and flipping at the screen edge. Without the script the browser's own tooltip shows |
| `pre > code` | `<pre><code class="language-ts">…</code></pre>` | a code block; see below |
| `pre.mermaid` | `<pre class="mermaid">flowchart LR …</pre>` | a diagram; see below |

## Code blocks

A code block is `<pre><code class="language-<lang>">` holding the text with `<`, `>` and `&` escaped; the loader hands it to the highlighter. `diff` tints added and removed lines across the block and mutes `@@` lines, so a sketch of a change needs no spans of your own. Real code takes `ts`, `js`, `bash`, `sql`, `yaml`, `json`, `py`, `go`, `rs`, `html`, `css`, `md`, or `plain`; a language the highlighter has no grammar for prints as plain text. Inline code is a bare `<code>`.

## Diagrams

A diagram is `<pre class="mermaid">`; the kit loads Mermaid only on a page that has one, and the page's CSS recolours its SVG from the kit's variables in both themes, whether the kit's loader or the host (Claude Artifacts) drew it. That covers flowcharts, sequence and state diagrams; another diagram type keeps Mermaid's own colours. A flow between screens, data changing shape with an example value per node, a sequence or a state diagram all use it. A node that carries an example value takes a Markdown string in backticks, so its label is bold and its value sits on the next line: ``menu["`**Menu**`` then a line break then ``status = paid`"]``; without the backticks the `**` prints as text. A diagram keeps its natural size and scrolls when wider than the column. A screen is a frame, never a diagram.
