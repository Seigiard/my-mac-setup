# Weekly Update

A written update for the manager: a Notion page named `<YYYY-MM-DD> Weekly Update`, in English. The manager reads it in three minutes, is not a native English speaker, and has not seen the tickets; he opens what he wants to check. It tells him what the week achieved for users and for the company, in his world, with a link on every result. Output is one `.md` file in the scratchpad unless the user names a place; the user pastes it into Notion.

The anchor is the bets page, read as `brief-format.md` describes. A bet's results document, when one exists, is read in full before its block is written.

## What goes in

The manager wants to know what users, partners, and the company gained this week, and what the bets now know. Every sentence passes one test: does the manager need it to see what the week achieved? What the writer tried on the way, ruled out, or found to be their own activity fails the test, however true it is; so does the share of a plan that got done, because it invites the question about the rest instead of showing the result.

The same week, told both ways:

> Process: We followed tagged links on production to a connected system and fixed every place the tag was lost; the re-run passed all cases but one that did not reproduce.
>
> Achievement: Links in outreach emails, on LinkedIn and on our site carry channel tags since 20 October, and the funnel counts sign-ups by channel. [#6487](…)

The first tells the manager what the writer did; the second tells him what the company has. Only the second goes in.

## Shape

500–700 words of prose, tables excluded. Paragraphs of two to four sentences, one idea each, and the first sentence carries the point. Headings name what is inside in plain words.

1. **In short** — written last, from the finished body, as a list: one bullet per bet in the body's order, then one bullet for what changed for users. A bet bullet starts with the bet's goal in the same plain words as its heading ("Seeing where visitors leave before connecting a system"), then the status word (open, extended, closed), then what the bet now knows. A reader who has never seen the bets page reads the list and knows these are bets and what each one is for. A bullet is one or two sentences.
2. **The bets**, the one that decides the next step first. The heading is the bet's goal in plain words, not its internal name. An open bet: a status line (open or extended, what is still missing against its own success conditions), and the numbers in a table of at most five rows. Each number names where it was read; when the rows share a source, name it once under the table, when they differ, name it in the row. A closed bet: the decision and its reason in one breath ("narrowed to errors, because errors in recordings were real defects and gestures were not"), then what the product and the people who use it have now because of it. A bet block carries the bet's progress only; a defect found on the way belongs under "What changed for users".
3. **What's next** — one short paragraph per candidate, with the place to look linked.
4. **What changed for users** (the changelog), grouped by surface (connecting a system, the partner page, screens), one bullet per change in the form `was → now. [#PR]`. Two to five bullets per surface.
5. **One line for the rest**: "About N small fixes and infrastructure improvements: <three or four words naming the kinds>." One sentence; the count is its only number.

## Links

A link sits at the sentence it proves, and a source appears once: a number links to its source line, a fix to its PR, a person's behaviour to the recording at the second it shows, a decision to its document. Link text says what opens ("the funnel", "recording, 0:31", "results"); the only bare identifier is the `[#PR]` that closes a was → now bullet.

The PR is the issue's `github` attachment from the step 2 query. Dashboards, recordings, screens, and documents are not in Linear: before writing, list every claim that still has no artifact and ask the user for the links in **one** question. A link that stays missing goes in as `[link needed: <what>]`, and the list of placeholders is reported outside the update.

## Facts once

Every fact appears once in the body and at most once in the summary, with the same number in both. A date or count stated in a status line is stated there only. The table carries the sample size; prose states the number and stops. A caveat about the data stays only when it changes the conclusion, and then as a clause.

## Language

Plain words a colleague from another team understands on first reading.
