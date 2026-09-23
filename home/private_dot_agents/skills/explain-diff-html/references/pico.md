# Pico on the explanation page

The template links `@picocss/pico@2.1.1/css/pico.min.css` from jsDelivr. Pico styles bare semantic HTML, so the page needs no classes beyond the layer in the template; it follows `prefers-color-scheme` on its own, and `<html data-theme="light|dark">` forces a theme.

## Layout

- `<main class="container">` is the page column; the template caps it at 52rem for reading.
- `<hgroup><h1>…</h1><p>…</p></hgroup>` renders the second line as a muted subtitle: the meta line under the title.
- `<nav><ul><li><a>…</a></li></ul></nav>` lays links out in a row: the table of contents.
- `<article>` is a card; `<header>` and `<footer>` inside it get their own bands. The stakeholder block is one.
- `<blockquote>` is the callout: a left border, muted text. Use it for a definition or an edge case that changes how the reader judges the code.
- `<figure><img><figcaption>` for frames; `<kbd>`, `<mark>`, `<ins>`, `<del>`, `<small>` all styled.

## Components, each by markup alone

| Component | Markup | On this page |
|---|---|---|
| Accordion | `<details><summary>…</summary>…</details>`; `name="x"` on several makes them exclusive; `<summary role="button">` renders as a button | Deep background, collapsed by default. |
| Card | `<article><header>…</header>…<footer>…</footer></article>` | Stakeholder block; a group in the walkthrough when it needs a title band. |
| Tooltip | `data-tooltip="…"` on any element, `data-placement="left|right|bottom"` | A term defined at first use: `<dfn data-tooltip="…">грант</dfn>`. |
| Nav | `<nav><ul>…</ul><ul>…</ul></nav>`, one `<ul>` per side; `<nav aria-label="breadcrumb">` for a path | Table of contents. |
| Progress | `<progress value="3" max="5">`; no `value` means indeterminate | A rollout or migration stage in Risks. |
| Loading | `aria-busy="true"` on any element shows a spinner | A frame of a state still loading, when the sketch must show it. |
| Group | `<fieldset role="group">` joins inputs and buttons into one bar | A `.ui` sketch of a search bar or a button row. |
| Dropdown | `<details class="dropdown"><summary>…</summary><ul><li>…</li></ul></details>` | A `.ui` sketch of a menu, such as an access chip. |
| Modal | `<dialog open><article>…</article></dialog>` | A `.ui` sketch of a dialog the change adds. |

Buttons and links take `class="secondary"`, `class="contrast"`, `class="outline"` for the muted, high-contrast, and hollow variants.

## Our layer

`pre.diff` with `.add` / `.del` lines, `.flow` boxes and arrows, the `.ui` mock, the stakeholder `dl` grid, and the risks checklist (`<li><label><input type="checkbox"> …</label></li>`, so the reviewer can tick items). The layer uses Pico variables (`--pico-primary`, `--pico-muted-color`, `--pico-muted-border-color`, `--pico-card-background-color`, `--pico-ins-color`, `--pico-del-color`, `--pico-border-radius`), so a new rule that uses them follows both themes.
