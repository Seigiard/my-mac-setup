# Reporting voice

How work done is told to a person who did not do it: a weekly update, a Slack update, a PR description, a Linear comment, an explanation of a change for a manager. Reached from the reporting pointer in `~/.claude/CLAUDE.md`, from the `work-summary` skill and its formats, from `pull-requests.md`, and from `explain-for-manager`. A format owns its sections, length, and order; this file owns the sentences inside them.

The reader lives in their own world: the product, its users, the company, the bets. They have not seen the tickets, the code, the session, or the earlier texts, and they open what they want to check. Every rule below serves one test: does the reader need this sentence to see what the work achieved, and can they verify it from the text alone?

## Achievements, not process

A sentence says what is now true for a user, a partner, an operator, or a bet. What the writer tried on the way, ruled out, measured about their own activity, or found to be their own test fails the test, however true it is. So does the share of a plan that got done ("eight of nine"): it invites the question about the rest instead of showing the result.

The same week, told both ways:

> Process: We followed tagged links on production to a connected system and fixed every place the tag was lost; the re-run passed all cases but one that did not reproduce.
>
> Achievement: Links in outreach emails, on LinkedIn and on our site carry channel tags since 20 October, and the funnel counts sign-ups by channel. [#6487](…)

The first tells the reader what the writer did; the second tells them what the company has.

## Was → now, with the artifact

A change is told as the state before and the state after, and the sentence that says shipped, fixed, works, or now ends with the artifact that proves it: the PR, the dashboard line, the recording at the second it shows, the document that records the decision, the live page. Link text says what opens ("the funnel", "recording, 0:31", "results"), and a source appears once: a number links to its source line, not every row to the same page. A claim with no artifact goes in as `[link needed: <what>]` and is named outside the text, never shipped as bare prose.

## Evidence bound

An artifact proves what it shows. A recording that ends on a screen shows a person who left it, not what the screen looked like. An issue description is a claim; the PR and its last comment are what was done. Say what is seen, and a cause only when an artifact shows it; otherwise the sentence stops at what is seen. A decision is told with its reason in one breath: "narrowed to errors, because errors in recordings were real defects and gestures were not".

## Facts once

Every fact appears once in the body and at most once in a summary, with the same value in both. The sample size goes in the table and the conclusion in prose. A caveat about the data stays only when it changes the conclusion, and then as a clause.

## Zero context

Each thing is named in words at the point of use: what the bet is for, what the screen does, who the person is. Internal names, stage numbers, ticket IDs, and the structure of the source ("side bet", "area 1", "stage 2") stay out of prose; a ticket ID lives only inside a link's text. Code stays out: no identifiers, file paths, or function names.

## The text is not about itself

No "as I said last week", no "briefly", no note that a section is deliberately short, no mention of how the text was produced. When the user asks for less, that means fewer words about the thing, not a sentence announcing brevity.

## Plain words

Words a colleague from another team understands on first reading. Sentences under 20 words, one idea each, active voice. Product names and on-screen labels stay as the product shows them. A text in another language keeps those labels in the product's language.

## The summary last

A summary ("In short", a TL;DR, a PR's first paragraph) is written after the body, from the body, and compresses meaning: the same facts in fewer words, never the body's phrases repeated.
