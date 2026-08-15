# Workstream Update Format

The update is posted to Slack by a workstream bot, attributed to the person, with a "View workstream" link beside it — so the text carries no greeting, no signature, and no ticket IDs. It follows one of two shapes below.

**Default: the focus-anchored shape.** Use it whenever the user stated a focus for the period — they usually paste the focus text they wrote at the start of it. Fall back to the flat shape only when no focus exists for the period.

## Focus-anchored shape (default)

Five parts, in this order:

1. **Focus line**: `Focus: <one sentence>`. Rewrite the user's own focus statement to a single line. Keep their words where they work; strip noun stacks.
2. **Shipped** (past tense, 1-2 paragraphs): what actually landed against that focus.
3. **Still ahead**: what the focus named and the week did not reach.
4. **Also**: work outside the focus, compressed hard.
5. **Closing line** — *only when the next period's focus differs from this one's*. See below.

### Shipped

- Conclusion first, mechanics second. Lead with the finding or the outcome that made the week matter, not with the ticket that carried it: "Document requests had never been used in production. Not once." then the cause, then the fixes.
- Compress parallel small work into one clause: "Plus a copy pass, so the carrier-facing side stops showing raw UUIDs and internal nouns" beats naming all three places.
- Short sentences and fragments land better here than one long clause chain.
- Work that landed just before the window still belongs here when the focus text names it as an open problem. Say so: "fixed just before this window".

### Still ahead

- Derive it from **open Linear issues**, not from re-reading the focus prose. An item the focus named may already be done, and a keyword search is what proves it.
- Say what is in progress versus untouched. "In progress" is a fact worth stating; do not imply either state.
- Never put finished work in this section, not even parenthetically. If a shipped fix sits on the same surface as an open gap, either move it to Shipped or drop it — a done thing inside "Still ahead" reads as a contradiction.

### Also

- Two or three sentences, maximum. Name the bucket ("test and contract infrastructure"), give the one concrete symptom worth telling, roll the rest into "a few small bugs".
- Heading word: "Also" or "On the side". Not "Off-focus" — it reads as a category label rather than a continuation of the story.

### Closing line

**Default: omit it.** The focus line at the top already says what the person is working on, so "Now continuing on the same focus" only restates it. Write a closing line only when the next period's focus genuinely differs from the one at the top — a new direction, or an addition to it ("plus making the screenshot tests more stable").

Never guess its content. Ask the user, or flag the line as a placeholder to replace. When the user gives a general answer, keep it general — do not sharpen it into specific tickets.

In the flat shape the closing line is mandatory: nothing else there says what comes next.

### Zero context

The zero-context rule in `SKILL.md` governs. Two additions for this shape:

- No ticket IDs, file paths, or PR numbers.
- Expand product-internal nouns on first use: "a shipment's rate card — the negotiated pricing table every booking inherits".

Length: ~250-350 words. Longer than the flat shape, because three sections earn their space.

### Example (fictional freight-platform product, from 21 done Linear issues + a stated focus)

> Focus: improving the UX of carrier–shipper coordination inside the platform.
>
> **Shipped.** Document requests — the platform's own way to ask a carrier for a missing paper — had never been used in production. Not once. The flow was broken at both ends: an operator could neither create a request nor send one. Both fixed. Sending now actually delivers, instead of minting a link nobody receives. The operator sees which bookings are waiting on a carrier. Plus a copy pass, so the carrier-facing side stops showing raw UUIDs and internal nouns.
>
> A shipment's rate card — the negotiated pricing table every booking inherits — now sits on the booking Overview, so the carrier gets the terms and not just a stream of receipts. Two trust-killers gone: the carrier-visible link that dead-ended in "Operator access required", and "5 listing fixs" on invoices.
>
> **Still ahead.** The two bigger pieces are untouched: a per-booking onboarding checklist covering documents and open decisions, and a guided flow for granting customs-broker permissions with automatic re-verification. The RELATED panel on a booking still stays empty despite active work, because nothing records document usage automatically. In progress. Two rough edges remain: custom service requests leave no record in the carrier's workspace, and the "Create your first booking" CTA contradicts the request-a-quote model.
>
> **Also.** Some time went on test infrastructure — screenshot reports kept degrading to baseline-less, reporting every story as new. Fixed that, plus a few small bugs.
>
> Now continuing on the same focus, plus making the screenshot tests more stable.

The closing line appears in this example because the next period adds screenshot-test stability to the focus; with an unchanged focus it would be omitted.

## Flat shape (no stated focus)

1. **Header**: `<Workstream> — Update for <YYYY-MM-DD>`. Workstream names are stable labels the team already uses, e.g. "Booking UX", "Operator Console", "Carrier Onboarding".
2. **Finished work** (past tense, 1-2 short paragraphs):
   - Lead with the biggest single accomplishment, stated as a product outcome.
   - Roll up scattered small work into outcome buckets: "auth reliability, session tooling, UI bugs, dead code cleanup".
   - Plain product language — "fixed google auth login redirect", "amazing speed-up". No ticket IDs, file paths, or PR numbers.
3. **Current focus** (one line, present tense): "Now focusing on X", "Now working on Y".

Length: ~50-120 words.

### Example (fictional freight-platform product)

> **Operator Console — Update for 2026-07-07**
>
> Finished a bunch of focused console fixes and cleanup.
>
> Fixed Inbox keyboard shortcuts for focused items outside the list. Fixed the stale workspace token flow that was causing 401 errors on long sessions. Added auto-title support for dispatch notes and removed the stale Test button from the header.
>
> Also removed the dead legacy-router package after the route-tree migration, fixed flaky activity-feed screenshot stories by freezing Date.now, and a few more.
>
> Mostly small but useful work around auth reliability, session tooling, UI bugs, dead code cleanup, and CI/test stability.
>
> Now focusing on navigation changes, better auto-titling for dispatch notes and other UX improvements

### Example produced by this workflow (same fictional product, from 28 done Linear issues)

> **Booking UX — Update for 2026-07-17**
>
> Finished the dispatch board migration — every shipment view now lives on a real URL with a single route tree instead of a stack of modal overlays. Cleaned up the navigation fallout on top: canonical URLs and breadcrumbs for carrier-owned shipments, panel exits now point to the parent booking, back buttons, active menu highlighting, and a handful of Settings polish fixes.
>
> Also closed out the repo-wide no-floating-promises lint ratchet — every package strict now, root flag flipped. Fixed a batch of CI stability issues along the way: flaky screenshot stories, a Storybook major-bump regression, a stale build cache breaking build:all.
>
> Now primarily focused on improving the UX of the documents section.

## Tone (both shapes)

- Casual, written for teammates, not reviewers. Impact over mechanics.
- Honest about incompleteness: "still has few small todos", "addressing most of the concerns, but not all of them yet".
