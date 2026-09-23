# Classes of the explanation page

The page is built on the render kit in `~/.claude/shared/render-kit.md`: semantic HTML, Pico's classes and attributes, `shj-lang-*` code blocks. On top of that the template adds these, and nothing else carries a class.

| Class | On | Effect |
|---|---|---|
| `toc` | `nav` | hidden in print; Pico lays the links out in a row |
| `stakeholder` | `article` | the `dl` inside becomes a two-column grid, labels in the accent colour, one column on phones |
| `checklist` | `ul` | no bullets; each `li` holds `<label><input type="checkbox"> …</label>` so the reviewer can tick it |
| `flow`, with `box` and `arrow` children | `div` | the data-flow family: boxes in a row with arrows between, stacked on phones; `<b>` in a box is its label, `<code>` its example value |
| `ui`, with `bar`, `row`, `btn`, `new` children | `div` | the sketch family, a labelled fallback when no frame exists: a title bar, rows, buttons, and an accent outline on what the change adds |
| `mermaid` | `pre` | rendered by Mermaid as a sequence or state diagram |

Everything else in the layer is tag-level and needs no class: reading width on `main`, `p`, `li`; borders on `figure img`; page-break rules for print.

A new rule in the layer uses Pico's variables (`--pico-primary`, `--pico-muted-color`, `--pico-muted-border-color`, `--pico-card-background-color`, `--pico-code-background-color`, `--pico-border-radius`, `--pico-spacing`) so it follows both themes.
