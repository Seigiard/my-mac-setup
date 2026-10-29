# Reporting voice

How work done is told to a person who did not do it, and how a problem is told to the person who owns it: a weekly update, a Slack update, a PR description, a Linear comment, a spoken brief, an explanation of a change for a manager. Reached from the reporting pointer in `~/.claude/CLAUDE.md`, from the `work-summary` skill and its formats, from `pull-requests.md`, and from `explain-for-manager`. A format owns its sections, length, and order; this file owns the sentences inside them.

The reader lives in their own world: the product, its users, the company, the bets. They have not seen the tickets, the code, the session, or the earlier texts, and they open what they want to check. Every rule below serves one test: does the reader need this sentence to see what the work achieved, and can they verify it from the text alone?

## Achievements

A sentence says what is now true for a user, a partner, an operator, or a bet. What the writer tried on the way, ruled out, or measured about their own activity fails the test, however true it is. So does the share of a plan that got done ("eight of nine"): it invites the question about the rest instead of showing the result.

The same week, told both ways:

> Process: We followed tagged links on production to a connected system and fixed every place the tag was lost; the re-run passed all cases but one that did not reproduce.
>
> Achievement: Links in outreach emails, on LinkedIn and on our site carry channel tags since 20 October, and the funnel counts sign-ups by channel. [#6487](…)

The first tells the reader what the writer did; the second tells them what the company has.

## Was → now, with the artifact

A change is told as the state before and the state after, and the sentence that says shipped, fixed, works, or now carries the artifact that proves it: the PR, the dashboard line, the recording at the second it shows, the document that records the decision, the live page. In a written text the artifact is a link at that sentence; in a spoken one it is named. Link text says what opens ("the funnel", "recording, 0:31", "results"), and a source appears once: a number links to its source line, not every row to the same page. A claim whose artifact is missing goes into a written text as `[link needed: <what>]`, and the list of placeholders is named outside the text.

## Evidence bound

An artifact proves what it shows. A recording that ends on a screen shows a person who left it, not what the screen looked like. An issue description is a claim; what was done is what the PR's diff and merge state show. Say what is seen, and a cause only when an artifact shows it; otherwise the sentence stops at what is seen. A decision is told with its reason in one breath: "narrowed to errors, because errors in recordings were real defects and gestures were not".

## A problem goes to its owner

A report to the person who owns an area says what is broken, shows the evidence, and describes the working state. The owner decides the fix. The title names the breakage as the owner meets it: the failing behaviour and its error. The body has three parts: what fails, the evidence, and "Done when" as a state the owner can observe. The reporter's own plan stays with the reporter, so the report carries facts and leaves the choices to the owner: no fix options to pick from, no request to confirm, no "otherwise we will".

## Facts once

Every fact appears once in the body and at most once in a summary, with the same value in both. The sample size goes in the table and the conclusion in prose. A caveat about the data stays only when it changes the conclusion, and then as a clause.

## Zero context

Each thing is named by what it does for the reader, in words, at the point of use: what the bet is for, what the screen does, who the person is. A release, flag, component, command, identifier, or file path is told as what the reader sees happen. A ticket ID lives inside a link's text.

## Every sentence is about the work

The text carries the work and its result. The reader does not know what they were told before or how the text was made, and the text does not tell them. When the user asks for less, that means fewer words about the thing.

## Plain words

Words a colleague from another team understands on first reading. Sentences under 20 words, one idea each, active voice. Product names and on-screen labels stay as the product shows them, in the product's language, whatever language the text is in.

## The summary last

A summary ("In short", a TL;DR, a PR's first paragraph) is written after the body, from the body: the body's facts compressed into fresh wording.
