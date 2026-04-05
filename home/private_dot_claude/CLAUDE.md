## Principles

### Epistemology

Assumptions are the enemy. Never guess numerical values - benchmark instead of estimating.
When uncertain, measure. Say "this needs to be measured" rather than inventing statistics.

### Phase 0 - Intent Gate (EVERY message)

**Key Triggers (check BEFORE classification):**

- External library/source mentioned → fire `open-source-librarian` background
- 2+ modules involved → fire Agent(subagent_type=Explore) background

**Skill Triggers (fire IMMEDIATELY when matched):**

| Trigger                                  | Skill                               | Notes                          |
| ---------------------------------------- | ----------------------------------- | ------------------------------ |
| Writing/implementing code                | `/rigorous-coding`                  | ALWAYS before implementation   |
| React useEffect, useState, data fetching | `/react-useeffect`                  | Before writing hooks           |
| "commit", "create commit"                | `/commit-commands:commit`           | Let skill handle git           |
| "commit and PR", "push and create PR"    | `/commit-commands:commit-push-pr`   | Full workflow                  |
| "review PR", "review this PR"            | `/git-pr-workflows:git-workflow`    | Review → PR with quality gates |
| "review code", "code review"             | `/comprehensive-review:full-review` | Multi-agent review             |
| Complex multi-step project starting      | `/superpowers:brainstorm`           | Persistent planning            |
| "review plan", "debate plan"             | `/review-plan`                      | Multi-agent plan review        |
**Request Classification & Handling:**

- **Exploratory** ("How does X work?") → fire explore + tools in parallel
- **Open-ended** ("Improve", "Refactor") → assess codebase first
- **GitHub Work** (@mention, "look into X and create PR") → full cycle: investigate → implement → verify → create PR
- **Ambiguous** → ask ONE clarifying question

**When you MUST ask:**

- Multiple interpretations with 2x+ effort difference
- Missing critical info (file, error, context)
- User's design seems flawed → raise concern before implementing
- Script timeout (>2min), sudo needed, blocker

## Conventions

- **Commit messages**: describe the actual change, not the trigger. "address review feedback" is banned — state what changed
- **GitHub CLI**: prefer `gh pr view`, `gh issue list`, `gh search prs` over `gh api`. Use `gh api` only when subcommands can't get the data
- **Commands in output**: must be copy-paste runnable, never abbreviated pseudocode
- **Research findings**: include steps another user can independently verify (exact commands + output)
- **New features**: iterate TDD-style (Red → Green → Refactor). Use `/tdd-integration` for strict cycle, `/superpowers:test-driven-development` before implementation
- **Reimplementation over refactoring**: when refactoring estimate exceeds 2x reimplementation effort (wrong language, heavy legacy, architectural mismatch) — build from scratch with human verification
- **Constraint persistence**: when user defines constraints ("never X", "always Y", "from now on") — immediately persist to appropriate CLAUDE.md, acknowledge, confirm

## Tools

### CLI Tools (via Bash)

- **AST search/refactoring**: `ast-grep` — for structural search (classes, functions, patterns)
- **JSON processing**: `jq` — for complex transformations
- **YAML, TOML, CSV, CBOR, Avro, MessagePack, Protobuf processing**: `rq` — for complex transformations
- **Code search**: `rg` with flags (`-t`, `-g`, `--json`) — when specific output format needed

### MCP Servers

**Tool selection guide:**

| Need                          | Primary tool                                                | Fallback           |
| ----------------------------- | ----------------------------------------------------------- | ------------------ |
| Library docs / API (inline)   | `mcp__plugin_context7-plugin_context7` (resolve → query)    | `mcp__deepwiki`    |
| Library docs (background)     | Agent(`context7-plugin:docs-researcher`)                    | `mcp__deepwiki`    |
| Library deep research         | Agent(`open-source-librarian`) — background                 | `mcp__deepwiki`    |
| How a specific repo works     | `mcp__deepwiki`                                             | Agent(Explore)     |
| Quick URL → markdown, no key  | `/markdown-new`                                             | `WebFetch`         |
| URL with selectors/auth/PDFs  | `mcp__jina__read_url`                                       | `/markdown-new`    |
| Web search                    | `mcp__jina__search_web` or `mcp__tavily-mcp__tavily_search` | `WebSearch`        |
| Deep multi-step research      | `mcp__tavily-mcp__tavily_research`                          | `mcp__jina__*`     |
| Site crawl / map              | `mcp__tavily-mcp__tavily_crawl`                             | `mcp__jina__*`     |

@RTK.md
