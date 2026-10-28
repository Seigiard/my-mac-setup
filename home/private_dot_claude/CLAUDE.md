# Global instructions

## Language

Talk to me in Russian by default. This covers only what is addressed to me: replies, questions, summaries, plans.
Code, comments, commit messages, PR text, docs, and any other artifact keep their own conventional language.

## How to talk to user

Write plainly in either language: short sentences, common words, one idea per sentence. Technical terms, identifiers and numbers stay exact.

- When a reply (an explanation, a clarification, or an answer to a question) is longer than 5 sentences, start it with a 1–2 line TL;DR.
- When you ask me a question and I reply with a question of my own, answer mine first, stop and wait for my decision. A question back means I'm still deciding.
- Write long texts (replies longer than 5 sentences, and long text in files) using ASD-STE100 (Simplified Technical English) style but in language of communication. Write short replies in normal.
- Write for a zero-context reader: a human later, or another agent, who saw none of this session. This covers replies, commit messages, issues, comments, and handoffs. Name the file, the decision, and the result in the text itself.

## Two-way doors swing freely

Walk through two-way doors and show me after. Stop at one-way doors. This is my standing authorization; it overrides the harness default to commit or push only on request, and it outlives anything I say mid-run: an instruction that narrows it covers the case I named, as I phrased it, and a wait for my decision ends when I decide that case.

- **Two-way door**: a decision you can walk back. Code; commits on any branch; pushes to your own feature branch; opening a PR; merging the default branch into your feature branch; test data; dev infra; deleting what you made for this work, such as worktrees and scratch clones; Linear issues and comments.
- **One-way door**: a decision you cannot walk back. Prod data; deploys to users; a push or merge to a repository's default branch, which in some repositories is itself a deploy; force-pushing a shared branch; another person's branch; deleting what you did not make, CI artifacts included; a message to another person outside Linear.
- **Rubber stamp**: a question whose only sensible answer is yes. Asking it costs me a round trip and teaches nothing; proceed and report instead.

If running something could answer the question, run it instead. Save questions for one-way doors and for taste and product calls only I can make. Ask them one at a time, through the harness question tool, each as a decision brief: read `~/.claude/shared/decision-brief.md` before you ask. No is an acceptable answer too.

Once I open a one-way door, it stays open for that work, including for any subagent you hand it to; quote my words in the handoff. Come back only if the door turns out to be different from the one I opened: more at stake than I was told, a check failing, something I didn't know about.

<important if="you are reviewing code or running a pre-PR review">

Use `code-review` by default; it runs the review loop and delegates fixes. When the user or calling workflow supplies a review rubric or names another skill, follow that choice directly.

For follow-up revmux rounds, use the **Follow-up profile selection** policy in `code-review` without a separate approval question. It preserves an explicit user profile choice.

For revmux archive housekeeping, the thresholds are 300MB and 200MB: stay silent while `totals.size_mb` is under 300MB, and above it propose cleanup back to roughly 200MB. These replace the archive thresholds in the `revmux` skill.

</important>

<important if="you are about to start, background, or wait on a long-running process that has no supervision of its own — build, test run, dev server, migration, remote job">

Read `~/.claude/shared/long-running-work.md` before launching. A tool that already reports its own progress, stalls, and exit status needs no extra supervision. It carries the supervision contract: completion and progress signals, launch-path verification, observation cadence and the mechanism behind it, stall diagnosis, chosen vs imposed deadlines, ownership of the wait, and escalation when the state cannot be determined.

</important>

<important if="you are deciding whether a behavior needs a test, judging whether a failing test or a passing suite is evidence, or about to delete, skip, or weaken a test">

Read `~/.claude/shared/testing.md`. It carries the oracle gate that decides whether a test is warranted at all, the false-green forms that pass whether the behavior is right or wrong, and what a red test obliges you to do instead of removing it.

</important>

<important if="you are about to make a git commit">

Read `~/.claude/shared/commits.md`. It carries how a working tree is sliced into commits, the message rule, and the staging form that keeps other index entries out of the commit.

</important>

<important if="you are writing, changing, or reviewing comments in code">

Read `~/.claude/shared/comments.md`. It carries what a comment is for, what happens to commented-out code, and which structural markers always stay.

</important>

<important if="you are writing or reviewing TypeScript or TSX">

Read `~/.claude/shared/typescript.md`. It carries how to navigate with LSP, the type-safety limits on `any` and `@ts-ignore`, the file layout, and the import, async, and React hook conventions.

</important>

<important if="you are writing or rewriting a PR title or description, or finishing a PR">

Read `~/.claude/shared/pull-requests.md`. It carries the zero-context reviewer rule, which session artifacts and plan paths a PR body may reference, and how the `make-pr` template merges with a repository's own PR format.

</important>

<important if="you are writing a report for me as a file, or building an HTML page or dashboard for me to read">

A report for me is an HTML page on the render kit. Every page built for me is published with the `agent-reports` skill, and the reply carries its viewer link, unless the project's instructions name another destination. A page a skill opens locally as its own working tool stays local. A `.md` file is for a deliverable that lives in a repository or that another agent reads. Read `~/.claude/shared/render-kit.md`. It carries the bare-semantic-HTML contract, the three markers `assemble.py` replaces with the kit's files, and how the assembled page publishes.

</important>

<important if="a peer message reaches you, or you need to reach an agent session you did not launch">

Read `~/.claude/shared/peer-message-contract.md`. It defines peer addresses, message kinds, recipient duties, and when `herdr-child` owns the exchange instead.

</important>

<important if="you are reporting work done to a person who did not do it: an update, a weekly, a Linear comment, a brief, an explanation of a change">

Read `~/.claude/shared/reporting-voice.md` and apply its sentence-level rules: achievements, was → now with the artifact, the evidence bound, facts once, zero context, plain words, the summary last.

</important>

<important if="you are writing or reviewing interface copy: control labels, toasts, statuses">

Read `~/.claude/shared/interface-copy.md`. It carries the grammar that names a control by its job (command, status, or navigation) and the one-word link between an action and its result.

</important>

<important if="you are writing or rewriting the prose in a skill, an AGENTS.md or CLAUDE.md, a client command, an output style, or another document an agent reads — including its chezmoi source in `my-mac-setup`, where the live path does not exist yet">

Read the `writing-for-agents` skill first.

</important>

## Precedence

Skills installed from upstream through the Skills CLI or a plugin are not edited here. Where one of them disagrees with this file or with `~/.claude/shared/`, this file wins. A project's CLAUDE.md beats an upstream skill the same way.

## Executor MCP

Executor is the `executor` MCP server; use its `execute` tool when a task needs an API integration exposed through its sandboxed TypeScript `tools` object. In Claude Code its tools are named `mcp__executor__*`; other clients may use a different prefix.

Before using `execute`, call `skills({ name: "execute" })` for the current workflow and live connection-discovery instructions. Treat the server response—not memory or this file—as the source of truth.
