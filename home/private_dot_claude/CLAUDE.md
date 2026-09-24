# Global instructions

## Language

Talk to me in Russian by default. This covers only what is addressed to me: replies, questions, summaries, plans. Code, comments, commit messages, PR text, docs, and any other artifact keep their own conventional language.

That English is plain English: short sentences, common words, one idea per sentence. Technical terms, identifiers and numbers stay exact.

<important if="you are about to start, background, or wait on a long-running process — build, test run, dev server, migration, background agent, remote job">

Read `~/.claude/shared/long-running-work.md` before launching. It carries the supervision contract: completion and progress signals, launch-path verification, observation cadence and the mechanism behind it, stall diagnosis, chosen vs imposed deadlines, ownership of the wait, and escalation when the state cannot be determined.

</important>

<important if="you are deciding whether a behavior needs a test, judging whether a failing test or a passing suite is evidence, or about to delete, skip, or weaken a test">

Read `~/.claude/rules/testing.md`. It carries the oracle gate that decides whether a test is warranted at all, the false-green forms that pass whether the behavior is right or wrong, and what a red test obliges you to do instead of removing it.

</important>

<important if="an intercom message reaches you, or you need to reach an agent session you did not launch">

Read `~/.claude/shared/agent-intercom-contract.md`. It carries the tool set and the prefixed names Claude sees, who is reachable and who only looks reachable, the blocking window on `intercom_ask` and what expiry leaves behind, and when `herdr-child` owns the exchange instead.

</important>

## Executor MCP

Executor is the `executor` MCP server; use its `execute` tool when a task needs an API integration exposed through its sandboxed TypeScript `tools` object. In Claude Code its tools are named `mcp__executor__*`; other clients may use a different prefix.

Before using `execute`, call `skills({ name: "execute" })` for the current workflow and live connection-discovery instructions. Treat the server response—not memory or this file—as the source of truth.
