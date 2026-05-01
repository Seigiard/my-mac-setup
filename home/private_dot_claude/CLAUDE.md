# Global instructions

Collaboration principles, skill triggers, and tool guidance applied across all projects.

## Always-on principles

- **Assumptions are the enemy**: never guess numerical values — benchmark instead. When uncertain, measure. Say "this needs to be measured" rather than inventing statistics.
- **Full completion**: if the user asked for N things, deliver all N before presenting results.

<important if="you are starting a new user request, classifying intent, or deciding which skill to invoke">

**Pre-classification triggers (fire in background before classifying):**

- External library/source mentioned → Agent(`open-source-librarian`) in background
- 2+ modules involved → Agent(subagent_type=Explore) in background

**Skill triggers (fire IMMEDIATELY when matched):**

| Trigger                                  | Skill                                     | Notes                        |
| ---------------------------------------- | ----------------------------------------- | ---------------------------- |
| Writing/implementing code                | `/rigorous-coding`                        | ALWAYS before implementation |
| React useEffect, useState, data fetching | `/react-useeffect`                        | Before writing hooks         |
| "commit", "create commit"                | `/compound-engineering:ce-commit`         | Let skill handle git         |
| "commit and PR", "push and create PR"    | `/compound-engineering:ce-commit-push-pr` | Full workflow                |
| "review PR", "review code"               | `/compound-engineering:ce-code-review`    | Multi-agent review           |
| Complex multi-step project starting      | `/compound-engineering:ce-brainstorm`     | Persistent planning          |
| Planning multi-step tasks                | `/compound-engineering:ce-plan`           | Structured breakdown         |
| Debugging, errors, test failures         | `/compound-engineering:ce-debug`          | Systematic root cause        |
| "review plan", "review spec"             | `/compound-engineering:ce-doc-review`     | Parallel persona review      |
| Linear issues, task tracking             | `/linear-cli`                             | Linear CLI management        |
| Executing work efficiently               | `/compound-engineering:ce-work`           | Quality + completion         |

**Request classification:**

- **Exploratory** ("How does X work?") → fire explore + tools in parallel
- **Open-ended** ("Improve", "Refactor") → assess codebase first
- **GitHub Work** (@mention, "look into X and create PR") → full cycle: investigate → implement → verify → create PR
- **Ambiguous** → ask ONE clarifying question

**When you MUST ask the user before proceeding:**

- Multiple interpretations with 2x+ effort difference
- Missing critical info (file, error, context)
- User's design seems flawed → raise concern before implementing
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

Describe the actual change, not the trigger. "address review feedback" is banned — state *what* changed.

</important>

<important if="you are using the GitHub CLI (gh)">

Prefer `gh pr view`, `gh issue list`, `gh search prs` over `gh api`. Fall back to `gh api` only when the subcommands can't return the data you need.

</important>

<important if="you are presenting commands or research findings to the user">

- Commands must be copy-paste runnable, never abbreviated pseudocode.
- Research findings must include steps another user can independently verify — exact commands and their output.

</important>

<important if="you are implementing a new feature or behavior">

Iterate TDD-style (Red → Green → Refactor). Use `/tdd-integration` for the strict cycle, or `/superpowers:test-driven-development` before implementation.

</important>

<important if="you are estimating refactor effort or scope of a rewrite">

When the refactor estimate exceeds 2x the reimplementation effort (wrong language, heavy legacy, architectural mismatch) — build from scratch with human verification, don't refactor.

</important>

<important if="you need to search files, search code contents, look up library docs, fetch URLs, or do web research">

**CLI tools (via Bash):**

- `ast-grep` — structural search/refactor (classes, functions, patterns)
- `jq` — JSON transformations
- `rq` — YAML, TOML, CSV, CBOR, Avro, MessagePack, Protobuf transformations
- `rg` with flags (`-t`, `-g`, `--json`) — when a specific output format is needed

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

@RTK.md
