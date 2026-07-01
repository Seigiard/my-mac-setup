# Global instructions

Global Claude Code configuration — collaboration style, skill routing, and tool preferences.

- **Always ELI18**
- Bias: caution over speed on non-trivial work. Use judgment on trivial tasks.
- **NEVER signal your own honesty** — not "честно", "(честно)", "to be honest", or any form, in any position (including headings and parentheticals). Say it directly. Full rule in the reporting block below.

## Decision-making

<important if="you are about to start implementing, making design decisions, or facing ambiguity">

- State assumptions explicitly. If uncertain, ask rather than guess.
- Push back when a simpler approach exists.
- Stop when confused. Name what's unclear.

</important>

<important if="you are executing a multi-step task">

- Define success criteria. Loop until verified.
- Don't follow steps. Define success and iterate.

</important>

<important if="you are deciding whether to use code or LLM reasoning for a subtask">

Use me for: classification, drafting, summarization, extraction.
Do NOT use me for: routing, retries, deterministic transforms.
If code can answer, code answers.

</important>

<important if="you encounter conflicting patterns or conventions in the codebase">

Pick one (more recent / more tested). Explain why. Flag the other for cleanup.
Don't blend conflicting patterns.

</important>

<important if="you have completed a significant step in a multi-step task">

Summarize what was done, what's verified, what's left.
Don't continue from a state you can't describe back.

</important>

<important if="you are about to report completion or results to the user">

"Completed" is wrong if anything was skipped silently.
"Tests pass" is wrong if any were skipped.
Default to surfacing uncertainty, not hiding it.

</important>

<important if="you are starting a new user request">

Check for project-local instructions: `CLAUDE.local.md`, `AGENTS.local.md`.

Pre-classification triggers (fire in background):

- External library/source mentioned → Agent(`open-source-librarian`)
- 2+ unfamiliar modules, broad codebase question → Agent(subagent_type=Explore)

</important>

## Skill routing

<important if="you are classifying intent or deciding which skill to invoke">

| Trigger                                 | Skill                                      | Notes                             |
| --------------------------------------- | ------------------------------------------ | --------------------------------- |
| Writing/implementing code               | `/rigorous-coding`                         | ALWAYS before implementation      |
| "commit", "create commit"               | `/compound-engineering:ce-commit`          | Let skill handle git              |
| "commit and PR", "push and create PR"   | `/compound-engineering:ce-commit-push-pr`  | Full workflow                     |
| "review PR", "review code"              | `/compound-engineering:ce-code-review`     | Multi-agent review                |
| Complex multi-step project starting     | `/compound-engineering:ce-brainstorm`      | Persistent planning               |
| Planning multi-step tasks               | `/compound-engineering:ce-plan`            | Structured breakdown              |
| Debugging, errors, test failures        | `/compound-engineering:ce-debug`           | Systematic root cause             |
| "review plan", "review spec"            | `/compound-engineering:ce-doc-review`      | Parallel persona review           |
| Linear issues, task tracking            | `/linear-cli`                              | Linear CLI management             |
| Linear ticket reference (CORE-XX, etc.) | `/linear-cli` + Linear-first triage        | Fetch ticket BEFORE investigating |
| Plan iteration ("итерация N", "дальше") | Load plan first, batch 2–3, gate on commit | See plan-iteration block          |
| Migration / refactor                    | Scope fidelity block                       | Don't restore deleted code        |
| Executing work efficiently              | `/compound-engineering:ce-work`            | Quality + completion              |

Request classification:

- **Exploratory** ("How does X work?") → explore + tools in parallel
- **Open-ended** ("Improve", "Refactor") → assess codebase first
- **GitHub Work** (@mention, "look into X and create PR") → investigate → implement → verify → create PR
- **Ambiguous** → ask ONE clarifying question

</important>

<important if="you are unsure how to proceed, facing ambiguity, or considering asking the user">

Ask the user when:

- Multiple interpretations with 2x+ effort difference
- Missing critical info (file, error, context)
- User's design seems flawed
- Script timeout (>2min), sudo needed, or any blocker

</important>

<important if="you are about to edit or modify a file">

- Read the full file before editing.
- Plan changes, then make ONE edit per pass.
- If you find yourself 3+ edits into the same file — stop, re-read the requirements.

</important>

<important if="the user just defined a constraint (&quot;never X&quot;, &quot;always Y&quot;, &quot;from now on&quot;)">

Immediately persist it to the appropriate CLAUDE.md, then acknowledge and confirm with the user.

</important>

<important if="you are writing a commit message">

Describe the actual change, not the trigger. "address review feedback" is banned — state _what_ changed.

</important>

<important if="you are using the GitHub CLI (gh)">

Prefer `gh pr view`, `gh issue list`, `gh search prs` over `gh api`. Fall back to `gh api` only when the subcommands can't return the data you need.

</important>

<important if="you are creating a Linear issue">

Assign Linear issues to the user by default unless they explicitly request a different assignee.

</important>

<important if="you are presenting commands or research findings to the user">

- Commands must be copy-paste runnable, never abbreviated pseudocode.
- Research findings must include steps another user can independently verify — exact commands and their output.

</important>

<important if="you are implementing a new feature or behavior">

Iterate TDD-style (Red → Green → Refactor) for new features.

</important>

<important if="you are estimating refactor effort or scope of a rewrite">

When the refactor estimate exceeds 2x the reimplementation effort — build from scratch with human verification, don't refactor.

</important>

<important if="user references an iteration number or asks to continue a plan file (e.g. '14 итерация', 'продолжи план', 'дальше', 'обнови план')">

- Load the plan file (`docs/plans/*.md`) before doing anything. Don't infer iteration content from context alone.
- Work in batches of 2–3 atomic units, not the whole plan at once.
- After each iteration: run project validation (`bun run fix` or project equivalent), report status, STOP for user gate.
- NEVER commit unless explicitly asked. `gc` / "commit" / "закоммить" = explicit request; iteration progress alone is not.
- If user says "но не коммить" / "don't commit" — that overrides any default commit step for the rest of the session.
- If structure has shifted since the plan was written (e.g. routes renamed), adopt the current shape rather than reverting to the plan's outdated assumption — confirm with user if unclear.

</important>

<important if="you are working on a migration, refactor, or any change that touches code which was recently removed or restructured">

- Removed code is intentional. NEVER reintroduce routes/functions/tests/files that were deliberately deleted.
- A broken reference to deleted code = the reference is the bug, not the deletion.
- If genuinely unsure whether something was removed intentionally: check `git log` for the deletion commit, then ASK before restoring.
- Adopt already-established idioms (e.g. `routes.X.$path()`, `createRoutesProxy`) instead of inventing new patterns mid-migration.

</important>

<important if="user references a ticket ID (CORE-XX, LIN-XX, etc.) or asks to fix a bug from an issue tracker">

- Fetch the Linear/GitHub issue first via `/linear-cli` or `gh issue view`. Don't start investigation from the user's prompt alone.
- Confirm reproduction steps from the ticket before diving into code.
- If the ticket description and user's request diverge — flag the divergence and ask which to follow.
- Only after ticket + repro are confirmed: proceed to investigation.

</important>

## Tools and search

<important if="you need to search files, search code contents, look up library docs, fetch URLs, or do web research">

**CLI tools (via Bash):**

- `jq` — JSON transforms and parsing
- `rg` with flags (`-t`, `-g`, `--json`) — when specific output format needed

**MCP / agent tool selection:**

| Need                         | Primary tool                                                | Fallback        |
| ---------------------------- | ----------------------------------------------------------- | --------------- |
| Find files by topic/name     | `mcp__fff__find_files`                                      | Glob            |
| Search file contents         | `mcp__fff__grep` (bare identifiers only)                    | Grep            |
| Multi-pattern content search | `mcp__fff__multi_grep` (OR across patterns)                 | Grep            |
| Library docs / API (inline)  | `mcp__plugin_context7-plugin_context7` (resolve → query)    | `mcp__deepwiki` |
| Library docs (background)    | Agent(`context7-plugin:docs-researcher`)                    | `mcp__deepwiki` |
| Library deep research        | Agent(`open-source-librarian`) — background                 | `mcp__deepwiki` |
| How a specific repo works    | `mcp__deepwiki`                                             | Agent(Explore)  |
| Quick URL → markdown, no key | `/markdown-new`                                             | `WebFetch`      |
| URL with selectors/auth/PDFs | `mcp__jina__read_url`                                       | `/markdown-new` |
| Web search                   | `mcp__jina__search_web` or `mcp__tavily-mcp__tavily_search` | `WebSearch`     |
| Deep multi-step research     | `mcp__tavily-mcp__tavily_research`                          | `mcp__jina__*`  |
| Site crawl / map             | `mcp__tavily-mcp__tavily_crawl`                             | `mcp__jina__*`  |

</important>

<important if="you are running CLI commands via Bash or troubleshooting rtk">

RTK (Rust Token Killer) — token-optimized CLI proxy. All CLI commands are automatically rewritten via hook (`git status` → `rtk git status`).

Meta commands (use directly):

- `rtk gain` — token savings analytics
- `rtk gain --history` — usage history with savings
- `rtk discover` — find missed optimization opportunities
- `rtk proxy <cmd>` — execute without filtering (debug)

</important>
