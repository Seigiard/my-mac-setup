# Render kit of the explanation page

Write semantic HTML and let the kit style it. The template links two libraries from jsDelivr, both following `prefers-color-scheme`: Pico 2.1.1 styles every bare element (`hgroup`, `nav`, `article`, `details`, `blockquote`, `figure`, `table`, `kbd`, `mark`, `ins`, `del`, `progress`, `dialog`, forms), and speed-highlight 2.1.0 colours code blocks. The whole class vocabulary of the page is the two tables below; an element outside them carries no class.

## Pico's classes, all of them

| Class | On | Effect | On this page |
|---|---|---|---|
| `container` | `main` | centred page column | already on `<main>` |
| `container-fluid` | `main` | full-width column | never |
| `grid` | `div` | equal columns, one column on phones | two frames side by side |
| `overflow-auto` | `figure` or `div` | scroll a wide table | a wide table |
| `striped` | `table` | zebra rows | a table with more than five rows |
| `secondary`, `contrast`, `outline` | `button`, `a`, `input[type=submit]` | muted, high-contrast, hollow variants | a `.ui` sketch of buttons |
| `dropdown` | `details` | a menu opened by `summary` | a `.ui` sketch of a menu |
| `modal-is-open`, `modal-is-opening`, `modal-is-closing` | `html` | scroll lock and transitions for `dialog` | never; a sketch shows `<dialog open>` static |

Attributes Pico reacts to: `data-tooltip` (+ `data-placement`) on any element, `aria-busy="true"` for a spinner, `role="group"` on `fieldset` or `div` to join controls, `role="button"` on `summary` or `a`, `aria-label="breadcrumb"` on `nav`, `name` on sibling `details` for an exclusive accordion, `rel="prev"` on a close button in a `dialog` header, `data-theme="light|dark"` on `html` to force a theme.

## Our classes, the template's layer

| Class | On | Effect |
|---|---|---|
| `toc` | `nav` | hidden in print; Pico lays the links out in a row |
| `stakeholder` | `article` | the `dl` inside becomes a two-column grid, labels in the accent colour, one column on phones |
| `checklist` | `ul` | no bullets; each `li` holds `<label><input type="checkbox"> …</label>` so the reviewer can tick it |
| `flow`, with `box` and `arrow` children | `div` | the data-flow family: boxes in a row with arrows between, stacked on phones; `<b>` in a box is its label, `<code>` its example value |
| `ui`, with `bar`, `row`, `btn`, `new` children | `div` | the sketch family, a labelled fallback when no frame exists: a title bar, rows, buttons, and an accent outline on what the change adds |
| `mermaid` | `pre` | rendered by Mermaid as a sequence or state diagram |
| `shj-lang-<lang>` | `div` | a code block coloured by speed-highlight |

Everything else in the layer is tag-level and needs no class: reading width on `main`, `p`, `li`; borders on `figure img`; page-break rules for print.

## Code blocks

A code block is `<div class="shj-lang-<lang>">` holding the text with `<`, `>` and `&` escaped; the highlighter keeps whitespace and wraps the lines itself. `diff` is the language of every sketch: lines starting with `+` or `-` turn green and red, `@@` lines and `---`/`+++` headers muted, everything else plain. Real code takes `ts`, `js`, `bash`, `sql`, `yaml`, `json`, `py`, `go`, `rs`, or `plain`. Inline code stays `<code>`, styled by Pico.

## Pico components by markup

| Component | Markup | On this page |
|---|---|---|
| Accordion | `<details><summary>…</summary>…</details>` | deep background, collapsed by default |
| Card | `<article><header>…</header>…<footer>…</footer></article>` | the stakeholder block; a walkthrough group that needs a title band |
| Tooltip | `<dfn data-tooltip="…">term</dfn>` | a term defined at first use |
| Nav | `<nav><ul><li><a>…</a></li></ul></nav>` | the table of contents |
| Progress | `<progress value="3" max="5">` | a rollout or migration stage in Risks |
| Loading | `<span aria-busy="true">…</span>` | a loading state in a sketch |
| Group | `<fieldset role="group"><input><button></fieldset>` | a search bar or button row in a sketch |
| Dropdown | `<details class="dropdown"><summary>…</summary><ul><li>…</li></ul></details>` | a menu in a sketch, such as an access chip |
| Modal | `<dialog open><article>…</article></dialog>` | a dialog the change adds, shown static in a sketch |
| Callout | `<blockquote>…</blockquote>` | an edge case or rule that changes how the reader judges the code |
| Title | `<hgroup><h1>…</h1><p>…</p></hgroup>` | the page title with the meta line under it |

A new rule in the layer uses Pico's variables (`--pico-primary`, `--pico-muted-color`, `--pico-muted-border-color`, `--pico-card-background-color`, `--pico-code-background-color`, `--pico-border-radius`, `--pico-spacing`) so it follows both themes.
