# Global instructions

<important if="you are about to start, background, or wait on a long-running process — build, test run, dev server, migration, background agent, remote job">

Read `~/.claude/shared/long-running-work.md` before launching. It carries the supervision contract: completion and progress signals, launch-path verification, observation cadence and the mechanism behind it, stall diagnosis, chosen vs imposed deadlines, ownership of the wait, and escalation when the state cannot be determined.

</important>

## Executor MCP

Executor is the `executor` MCP server; use its `execute` tool when a task needs an API integration exposed through its sandboxed TypeScript `tools` object. In Claude Code its tools are named `mcp__executor__*`; other clients may use a different prefix.

Before using `execute`, call `skills({ name: "execute" })` for the current workflow and live connection-discovery instructions. Treat the server response—not memory or this file—as the source of truth.
