# Weekly Update Format

A written update for the manager: a Notion page named `<YYYY-MM-DD> Weekly Update`, in English. It is read, not spoken, and the reader's test for every result is "where can I see it?". A result with no link is a claim; an artifact is the signal. Output is one `.md` file in the scratchpad unless the user names a place; the user pastes it into Notion.

The weekly shares its anchor and its section logic with the brief: read the bets page and cluster issues into stories as `brief-format.md` describes. What differs is below.

## Shape

Four `##` sections: **Bets**, **UI/UX**, **Bugs**, **What's next**.

**Bets.** One block per active bet, led by a status line:

> **Conversion funnel** — open. The funnel from first visit to a connected system refreshes every morning and splits by channel. [Dashboard](…) · [PR](…)

Then the evidence. Numbers go in a table, one row per step or period, with a link in the cell where the number was read. Then at most one short paragraph of story: what was learned and what it changes. A recording or a query that the conclusion rests on is linked at the sentence that uses it.

**UI/UX** and **Bugs.** One bullet per change, "was → now", ending with its PR link. A change on a public surface also links the surface itself (a published profile, a client page). Group bullets under a bold lead-in per surface when there are more than four.

**Leftover.** One line, "About N small fixes and infrastructure improvements", followed by a Notion toggle block `All N issues` that lists every leftover issue as `PRD-XXXX — title`, each linked. Count N from the issues named nowhere else.

**What's next.** One paragraph per candidate bet: what will be looked at, where, and what decides the call. Link the place: the dashboard, the page, the recording set.

## Artifact rule

Every sentence that says shipped, fixed, works, or now ends with a link. The sources, in the order to try:

| Claim | Artifact |
| --- | --- |
| a change landed | the PR: the issue's `github` attachment from the step 2 query; the Linear issue `url` when there is no PR |
| a number | the dashboard, insight, or query it was read from |
| a person did or saw something | the recording, at the second it shows |
| a decision was made | the document or thread that records it |
| a thing exists in the product | the live page |

Dashboards, recordings, and documents are not in Linear. Before writing, list every claim that still has no artifact and ask the user for the links in **one** question. A claim that stays without one goes into the file as `[link needed: <what>]` and is named outside the file; it is never shipped as bare prose.

## Evidence bound

An artifact proves what it shows and nothing more. A recording that ends on the first screen shows a person who left from the first screen; whether the screen was blank is a separate fact that needs its own artifact. Say what is seen, not what is inferred, and when the inference matters, label it: "likely because…".

## Length

300–450 words of prose. Tables, link lines, and the toggle list do not count. When the text runs over, cut story paragraphs before cutting a link or a table row.

## Example (excerpt, 22 Oct 2026)

> ## Bets
>
> **Conversion funnel** — open. Built: the funnel from first visit to a connected system, refreshed every morning, split by channel; staff, test accounts, and partners are excluded. [Dashboard](https://…/insights/…) · [PR](https://github.com/…/pull/6701)
>
> | Period | Visitors | Sign-ups | Connected | Source |
> | --- | --- | --- | --- | --- |
> | 15–19 Oct | 76 | 0 | 0 | [funnel](https://…/insights/…) |
> | 19 Oct | — | 1 | 0 | [recording](https://…/replay/…) |
>
> The one sign-up left from the first screen without trying to connect a system; the recording ends there. The same days, the server refused the first open of an idle workspace ten times across three workspaces, fixed in [#6708](https://github.com/…/pull/6708). Too few recordings to say anything about client behavior yet.
>
> ## UI/UX
>
> **Partners.** Of four partners invited this week, three published within minutes ([profile](…), [profile](…), [profile](…)); one got stuck, and the fixes follow her path ([issue](https://linear.app/…/PRD-3636)).
>
> - A complete draft profile asked the partner to fill what was already filled → it offers publishing from the save bar. [#6723](https://github.com/…/pull/6723)
> - A link to an unpublished profile said "this profile isn't here" → it says the profile is coming. [#6718](https://github.com/…/pull/6718)
>
> ## Bugs
>
> - Pressing Connect on Home blinked the whole page → only the relevant block reacts. [#6690](https://github.com/…/pull/6690)
>
> About 30 small fixes and infrastructure improvements.
>
> ▸ All 30 issues
> · PRD-3633 — one inline form for a text link inside a sentence
> · …
>
> ## What's next
>
> **Partner's path.** Of 21 partners added, 6 signed in and 3 published; none was invited through the product. The partner funnel is instrumented and lands in [this dashboard](https://…) after the deploy. If it shows the same losses, the next bet is the path from invitation to a published profile.
