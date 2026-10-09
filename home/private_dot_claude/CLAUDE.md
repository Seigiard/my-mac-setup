# Global instructions

## Language

Talk to me in Russian by default. This covers only what is addressed to me: replies, questions, summaries, plans.
Code, comments, commit messages, PR text, docs, and any other artifact keep their own conventional language.

## How to talk to user

That English is plain English: short sentences, common words, one idea per sentence. Technical terms, identifiers and numbers stay exact.

- When a reply (an explanation, a clarification, or an answer to a question) is longer than 5 sentences, start it with a 1–2 line TL;DR.
- When you ask me a question and I reply with a question of my own, answer mine first, stop and wait for my decision. A question back means I'm still deciding.
- Write long texts (replies longer than 5 sentences, and long text in files) using ASD-STE100 (Simplified Technical English) style but in language of communication. Write short replies in normal.

<important if="you are reviewing code or running a pre-PR review">

Use `code-review` by default; it runs the revmux review-fix loop. When the user or calling workflow supplies a review rubric or names another skill, follow that choice directly.

For follow-up revmux rounds, use the **Follow-up profile selection** policy in `code-review` without a separate approval question. It preserves an explicit user profile choice.

</important>

<important if="you are about to start, background, or wait on a long-running process that has no supervision of its own — build, test run, dev server, migration, remote job">

Read `~/.claude/shared/long-running-work.md` before launching. A tool that already reports its own progress, stalls, and exit status needs no extra supervision. It carries the supervision contract: completion and progress signals, launch-path verification, observation cadence and the mechanism behind it, stall diagnosis, chosen vs imposed deadlines, ownership of the wait, and escalation when the state cannot be determined.

</important>

<important if="you are deciding whether a behavior needs a test, judging whether a failing test or a passing suite is evidence, or about to delete, skip, or weaken a test">

Read `~/.claude/shared/testing.md`. It carries the oracle gate that decides whether a test is warranted at all, the false-green forms that pass whether the behavior is right or wrong, and what a red test obliges you to do instead of removing it.

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

<important if="you are building an HTML page, report, or dashboard, or publishing one as a Claude Artifact">

Read `~/.claude/shared/render-kit.md`. It carries the bare-semantic-HTML contract, the three markers `assemble.py` replaces with the kit's files, and why the assembled page publishes to an Artifact as it is.

</important>

<important if="an intercom message reaches you, or you need to reach an agent session you did not launch">

Read `~/.claude/shared/agent-intercom-contract.md`. It carries the tool set and the prefixed names Claude sees, who is reachable and who only looks reachable, the blocking window on `intercom_ask` and what expiry leaves behind, and when `herdr-child` owns the exchange instead.

</important>

<important if="you are writing or reviewing interface copy: control labels, toasts, statuses">

Read `~/.claude/shared/interface-copy.md`. It carries the grammar that names a control by its job (command, status, or navigation) and the one-word link between an action and its result.

</important>

<important if="you are writing or rewriting the prose in a skill, an AGENTS.md or CLAUDE.md, a client command, an output style, or another document an agent reads — including its chezmoi source in `my-mac-setup`, where the live path does not exist yet">

Read the `writing-for-agents` skill first.

</important>

## Executor MCP

Executor is the `executor` MCP server; use its `execute` tool when a task needs an API integration exposed through its sandboxed TypeScript `tools` object. In Claude Code its tools are named `mcp__executor__*`; other clients may use a different prefix.

Before using `execute`, call `skills({ name: "execute" })` for the current workflow and live connection-discovery instructions. Treat the server response—not memory or this file—as the source of truth.
