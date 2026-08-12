# Report Format

Themed breakdown for the user's own consumption — 1:1 prep, standup detail, retrospective, perf-review raw material. Ticket IDs stay in; the reader may want to drill down.

## Structure

1. **Header line**: total count + range, e.g. "28 issues completed 12–17 July."
2. **Theme sections** (one per meaningful group, 4-6 max):
   - Heading: theme name + issue count, e.g. `### Lint strictness ratchet — no-floating-promises endgame (7 issues)`
   - 1-3 sentences summarizing the outcome of the group as a whole.
   - Issue references inline (`FRT-2034`) or as a short list — inline when the narrative carries them, listed when they're parallel items.
3. **TLDR**: one closing sentence compressing the whole period.

Order themes by significance, not chronology. A large migration and its fallout form one theme ("FRT-1731 — the big one: ... Fallout/polish on top of it: ..."); scattered fixes roll up into a named bucket.

## Example (fictional freight-platform product, 28 issues)

> **28 issues completed 12–17 July.**
>
> ### Lint strictness ratchet — `no-floating-promises` endgame (7 issues)
>
> Repo-wide campaign completed: pinned already-clean packages (FRT-2028), fixed and enabled the rule in carrier-sdk (FRT-2029), cli (FRT-2030), console — 214 spots/89 files (FRT-2032), and booking-api — 310 spots/61 files (FRT-2033). Then flipped the root config default and removed per-package pins (FRT-2034). Follow-up `require-await` flip also landed (FRT-2045).
>
> ### Dispatch board migration + navigation/breadcrumbs (6 issues)
>
> - **FRT-1731** — the big one: migrated the dispatch board from a stack of modal overlays to a real route tree, so every shipment view has a URL.
> - Fallout/polish on top of it: carrier-owned shipments now get canonical URLs and breadcrumbs (FRT-2107), the rate-card panel breadcrumb exits to the parent booking instead of the flat list (FRT-2101), missing Back buttons added (FRT-1922), active menu highlighting in Settings (FRT-2094).
>
> ### CI / visual-test / build reliability (5 issues)
>
> - Fixed the app build replaying a stale asset bundle that broke `build:all` after export removals (FRT-2230).
> - Storybook: bumped the catalog a major version (FRT-1932) and fixed the focus-spy regression it caused in screenshot capture (FRT-2027).
> - Screenshot flakes: broken invoice stories failing console checks on every PR (FRT-2098), 5 flaky board stories (FRT-1513).
>
> *(further themes elided)*
>
> **TLDR:** week = closed out the `no-floating-promises` ratchet, landed the dispatch board migration plus its navigation fallout, and cleaned up a batch of CI/screenshot flakes.
