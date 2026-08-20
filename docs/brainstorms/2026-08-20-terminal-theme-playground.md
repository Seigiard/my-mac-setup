# Terminal theme playground — brainstorm

Date: 2026-08-20. Status: brainstorm, no decision taken.
Related: `docs/issues/2026-08-20-003-pi-terminal-theme-hex-vars-red-test.md` (the failing test that triggered this, plus its undesigned "theme tester" half).

## Problem

This repo holds TUI themes for four tools — Claude Code, opencode, pi, herdr. The contract (enforced by bats tests since `ee5357b feat(agents): inherit terminal color palettes`) is: **themes reference the terminal's ANSI palette slots, never baked hex**, so every tool follows the terminal scheme automatically.

Two gaps:

1. **No way to verify the contract visually.** The pi theme drifted — four `vars` in `home/dot_pi/agent/themes/terminal.json:12-15` are hex (`#6F6E69`, `#878580`, `#B7B5AC`, `#F2F0E5`), which `tests/scripts.bats:4726` now catches. Worse, the hex was copied from the Flexoki palette (ghostty's theme) while kitty is pinned to Alabaster — wrong for one of the two managed terminals either way. A test catches the *syntax* (hex vs index); nothing shows what the theme actually *looks like* under a given palette.
2. **No way to design.** Picking which ANSI slot a token should use (is `muted` better as `7` or `8` on Alabaster? on Flexoki?) is currently guess → commit → apply → look.

Desired: a browser playground — input the terminal's 16 ANSI colors (+ fg/bg), see mock layouts of all four tools rendered through their *actual* theme files, tweak token→slot assignments live, export the theme files back.

## Current state: four tools, four dialects

All four tools natively support terminal-palette references. Verified against official docs/source (mid-2026):

| Tool | Theme file | ANSI/terminal syntax | In this repo now |
|---|---|---|---|
| Claude Code | `~/.claude/themes/<slug>.json` → `{name, base, overrides}`; selected via `"theme": "custom:<slug>"` | `ansi:<name>` (16 names, e.g. `ansi:cyanBright`), `ansi256(n)`, plus hex/`rgb()`; bases incl. `light-ansi`, `dark-ansi` | `home/private_dot_claude/themes/light-ansi-daltonized.json` — pure `ansi:`, green test |
| opencode | `~/.config/opencode/themes/*.json` → `{defs, theme}` (~50 tokens) | bare integer `0–255` (0–15 = terminal ANSI), `none`/`transparent`, `{dark,light}` variants; built-in `system` theme reads the OSC-reported palette | `tui.json` → `"theme": "system"` (inherits everything, zero custom colors) |
| pi | `~/.pi/agent/themes/*.json` → `{name, vars, colors}` (51 required tokens) | integer `0–255`, `""` = terminal default, var references; **hot reload** on edit | `home/dot_pi/agent/themes/terminal.json` — mixed, 4 hex vars → **red test** |
| herdr | `~/.config/herdr/config.toml` → `[theme]` + `[theme.custom]` | built-in theme `terminal` follows the host ANSI palette; custom overrides accept hex, named colors, `rgb()`, `reset` aliases | `name = "rose-pine-dawn"` + `panel_bg = "reset"` — a fixed-color theme, *not* palette-following |

Claude Code also hot-reloads `~/.claude/themes/` on change. Both hot-reload paths matter for Option D below.

The terminal palettes themselves: kitty's active palette is explicit in-repo (`home/private_dot_config/kitty/Alabaster.conf:30-59`); ghostty only names its built-in (`theme = Flexoki Light`), but the same 16 colors exist in-repo as the commented-out `kitty/flexoki-light.conf:17-32`. So both candidate palettes are available as data.

## Prior art

**The five links, examined:**

- **RandolfTjandra/claude-theme-builder** (MIT) — single self-contained `index.html` (~592 lines, vanilla JS, opens from `file://`). Preview is a static HTML/CSS mock of the Claude Code UI (message bubbles, diff hunk, permission dialog, autocomplete, shimmer animations), driven entirely by CSS custom properties: change a picker → `p.style.setProperty('--ck-'+key, …)` → the mock re-skins. Clicking a preview surface highlights the controls that feed it (`data-uses` mapping). 57-token schema reverse-engineered from the binary. **Limitation:** export normalizes everything to hex — it cannot emit `ansi:`/`ansi256()` values, i.e. it does exactly what our contract forbids. The preview technique and the design doc (`docs/superpowers/specs/…-design.md`) are the reusable parts.
- **kkugot/opencode-theme-studio** (MIT, React 19 + Vite) — the strongest architectural reference. Three-tier editing (semantic groups → per-token → raw JSON with validation), curated presets, contrast checking, and a mock TUI preview. Crucially it **re-implements opencode's own theme resolver** (`src/domain/opencode/resolveTheme.ts`) and vendors the built-in theme JSONs, so the preview resolves real theme files, not an ad-hoc model.
- **nxxxsooo/opencode-themes** — not a tool and not opencode themes: a fixed palette shipped as Obsidian/Typora CSS, a ghostty theme, and a pi theme. Only useful as palette data. Skip.
- **MikeCase/opencode-config-builder** — a visual `opencode.jsonc` editor (models, agents, MCP); zero theme support, no license. Skip.
- **pi.dev/docs/latest/themes** — gives the full 51-token schema, the four value formats, and `$schema` validation (`theme-schema.json`). Also opens with: "pi can create themes. Ask it to build one for your setup."

**Added from my own search:**

- **terminal.sexy** — the classic 16-color palette designer with generic terminal previews and multi-format export. Proves the palette-editor UX but knows nothing about tool-specific layouts.
- **tinted-theming / base16 + Tinted Gallery** (tinted-theming.github.io/tinted-gallery) — the mature "one palette → templates for hundreds of apps" ecosystem, with a browser gallery that previews schemes in a fake terminal. Closest conceptual model. **Structural mismatch, though:** base16 templates *bake hex* into every app config — the exact opposite of this repo's slot-referencing contract. Their model is "regenerate all configs when the palette changes"; ours is "configs never change, the terminal palette is the single variable."

Nobody has built the specific thing: a multi-tool playground where the **palette is the input and slot-referencing theme files are the artifact**. claude-theme-builder and theme-studio are single-tool and hex-centric; base16 is many-tool but hex-baking.

## Concept

One page, three columns:

1. **Palette panel** — 16 ANSI swatches + default fg/bg, editable; preset dropdown: Alabaster (from `kitty/Alabaster.conf`), Flexoki Light (from `kitty/flexoki-light.conf`), a few ghostty built-ins, paste-a-base16-YAML import.
2. **Theme editors** — one tab per tool, loaded with this repo's actual theme files. Each token row shows the token name and a **select of palette slots** (0–15, `default`, plus a hex escape hatch that visibly flags the token as "breaks the contract"). A raw-JSON/TOML view mirrors state both ways.
3. **Previews** — four mock layouts (Claude Code, opencode, pi, herdr sidebar), each rendered by resolving its theme file against the current palette, exactly as the real tool would: implement the four small resolvers (`ansi:<name>` names; bare ints with the 0–15 = palette / 16–231 cube / 232–255 ramp split; `""`/`none`/`reset` = terminal default; var/defs references).

Interactions that make it a playground: switch palette preset → all four previews re-skin instantly (the whole point of slot-referencing themes, made visible); click a preview surface → jump to the token that colors it (claude-theme-builder's `data-uses` trick); export → the four files in their exact repo dialects.

Mock fidelity target: the surfaces where color choices actually bite — user/assistant message, tool-call box (pending/success/error), diff hunk, markdown block, syntax-highlighted code, borders/muted/dim text hierarchy. Not pixel-perfect chrome; claude-theme-builder's design doc explicitly takes the same stance and it works.

### The token→surface map — the core work item, mostly already done elsewhere

The playground stands on knowing what each token colors in each tool's rendered UI. Per tool:

- **pi** — the official docs table lists all 51 tokens with the purpose of each (`toolPendingBg`, `mdHeading`, `thinkingMedium`, …), and the repo ships reference `dark.json`/`light.json`. Ambiguous cases are cheap to verify empirically: pi hot-reloads the active theme file on save, so "change token → watch live pi → encode in the mock" is a tight loop.
- **Claude Code** — claude-theme-builder (MIT) already carries the 57-token schema reverse-engineered from the binary *and* a mock where every preview surface declares its tokens via `data-uses` attributes. That mapping transfers wholesale.
- **opencode** — opencode-theme-studio (MIT) already carries the mock-to-token mapping in `PreviewSurface.tsx` plus a re-implementation of opencode's resolver. The mapping transfers even if the playground is not React.

So "understand every token" is not three binaries to reverse-engineer: it is one docs table plus hot-reload experiments (pi), and two MIT-licensed maps to port and spot-check against the real tools (Claude Code, opencode).

## Options

**Option A — single-file static playground (recommended).** One `index.html`, vanilla JS + CSS variables, no build, in the pattern claude-theme-builder proved viable at ~600 lines for one tool. Four resolvers are each ~30–60 lines. Lives in this repo (e.g. `tools/theme-playground/index.html`), opens from `file://`, publishable as a Claude artifact for sharing. The `playground` skill in this setup builds exactly this shape of artifact. Effort: small — the formats are documented above, two MIT repos donate the preview technique.

**Option B — canonical role map + generator.** Go further: define one source file (palette-slot → semantic-role assignments), write a generator that *emits* all four dialect files, and let the playground edit the canonical map instead of four dialects. Same pattern as the existing `writing-style.md` single-source setup and base16 templates (but emitting slot references, not hex). Kills the whole drift class the failing test caught — the four files can no longer disagree. Costs: a generator to maintain, chezmoi integration for generated files, and lost freedom to hand-tune per tool (pi's 51 tokens don't map 1:1 onto Claude's 57 or herdr's chrome keys — the role map needs per-tool exception syntax almost immediately).

**Option C — ride tinted-theming.** Write base16 templates for the four dialects and use tinty/Tinted Gallery. Rejected as the primary path: base16 emits hex, which violates the repo's palette-only contract; the gallery previews a generic terminal, not these four layouts. Only worth revisiting if the goal ever flips to "many pre-baked colorful themes" instead of "follow the terminal."

**Option D — no browser at all: hot reload + real terminals.** pi and Claude Code both hot-reload theme files, and pi's own docs suggest asking the agent to build themes. A zero-build "tester": a script that opens the tools in panes (herdr makes this natural), plus a palette-switcher that toggles kitty between `Alabaster.conf` and `flexoki-light.conf`. Maximum fidelity (it *is* the real rendering), zero mock-drift risk. But: no side-by-side across palettes, requires applying configs to the live machine (this repo deliberately forbids casual `chezmoi apply`), and gives no token→surface discoverability. Honest floor to measure A against — if A's mocks ever feel like maintenance, D is the fallback.

**Recommendation: A now, keep B as the evolution if drift recurs, D as the cheap companion for final visual sign-off.** A is the only option that delivers the stated wish (see all four side by side, switch palettes, tweak with slot selects) and it subsumes nothing that blocks B later — the resolvers and mocks carry over.

## Risks and unknowns

- **Mock drift.** Token lists move with tool versions (pi's schema is versioned via `$schema`; Claude's 57-key list is partly reverse-engineered; opencode's type omits `number` from `ColorValue` even though the runtime accepts it). Mitigation: vendor each tool's token list with a version note; the bats tests remain the contract's enforcement, the playground is only eyes.
- **ANSI-name mapping for Claude.** `ansi:<name>` names (`red`…`whiteBright`) map to slots 0–15 predictably, but the mapping should be written down once in the playground, not assumed per-surface.
- **herdr scope.** Its theme colors are UI chrome (sidebar, rows), not chat surfaces; a v1 could drop the herdr pane, or first switch the repo config from `rose-pine-dawn` to the built-in `terminal` theme so herdr joins the same contract at all — that's a repo decision independent of the playground.
- **ghostty palette is not data in-repo.** The playground presets read kitty conf files; if ghostty ever moves off a kitty-mirrored theme, its palette needs vendoring.

## Out of scope here, already tracked

The red test itself needs no playground: replace the four hex vars in `home/dot_pi/agent/themes/terminal.json` with slots `7` (mutedText, dimText — or `7`/`8` split), `8` (subtleLine), `15` (softBg), per issue `2026-08-20-003`. That issue also holds the "theme tester" open decision this document now answers.

## Open decisions

1. ~~Where the playground lives~~ — **decided 2026-08-20: separate repo, deployed as a static site on GitHub Pages or Cloudflare Pages.** A single-file/no-build page fits both hosts with zero CI beyond a deploy action.
2. ~~Option A vs going straight to B~~ — **decided 2026-08-20: Option A.** The intended interaction is per-tool: open a tool's tab, edit its native theme JSON token by token, watch the emulated interface of that tool re-render live. A canonical master map (B) contradicts that model; it stays only as a possible later evolution.
3. ~~herdr in v1~~ — **decided 2026-08-20: postponed.** v1 covers Claude Code, opencode, pi. (The separate question of migrating this repo's herdr config to `theme.name = "terminal"` stays with the repo, not the playground.)
4. ~~Export mechanics~~ — **decided 2026-08-20: copy-to-clipboard per tool** (the theme JSON for Claude Code / pi / opencode), applied manually by the user. No chezmoi integration, no file writing, no bundle download.
