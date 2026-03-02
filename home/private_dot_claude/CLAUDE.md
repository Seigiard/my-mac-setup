<claude-instructions>

<principles>

<epistemology>
Assumptions are the enemy. Never guess numerical values - benchmark instead of estimating.
When uncertain, measure. Say "this needs to be measured" rather than inventing statistics.
</epistemology>

<behavior-instructions>

## Phase 0 - Intent Gate (EVERY message)

### Key Triggers (check BEFORE classification):

- External library/source mentioned → fire \`open-source-librarian\` background
- 2+ modules involved → fire Agent(subagent_type=Explore) background

### Skill Triggers (fire IMMEDIATELY when matched):

| Trigger                                  | Skill                               | Notes                          |
| ---------------------------------------- | ----------------------------------- | ------------------------------ |
| Writing/implementing code                | `/rigorous-coding`                  | ALWAYS before implementation   |
| React useEffect, useState, data fetching | `/react-useeffect`                  | Before writing hooks           |
| "commit", "create commit"                | `/commit-commands:commit`           | Let skill handle git           |
| "commit and PR", "push and create PR"    | `/commit-commands:commit-push-pr`   | Full workflow                  |
| "review PR", "review this PR"            | `/git-pr-workflows:git-workflow`    | Review → PR with quality gates |
| "review code", "code review"             | `/comprehensive-review:full-review` | Multi-agent review             |
| Complex multi-step project starting      | `/superpowers:brainstorm`           | Persistent planning            |
| Fetch URL content as markdown            | `/markdown-new`                     | Free, no API key               |
| URL with CSS selectors, PDFs, auth       | `/jina-reader`                      | Needs JINA_API_KEY             |
| Web search, deep research via curl       | `/tavily` or `/jina-reader`         | When MCP tools unavailable     |

### Step 1: Classify Request Type

| Type            | Signal                                            | Action                                                       |
| --------------- | ------------------------------------------------- | ------------------------------------------------------------ |
| **Trivial**     | Single file, known location, direct answer        | Direct tools only (UNLESS Key Trigger applies)               |
| **Explicit**    | Specific file/line, clear command                 | Execute directly                                             |
| **Exploratory** | "How does X work?", "Find Y"                      | Fire explore (1-3) + tools in parallel                       |
| **Open-ended**  | "Improve", "Refactor", "Add feature"              | Assess codebase first                                        |
| **GitHub Work** | @mention in issue/PR, "look into X and create PR" | **Full cycle**: investigate → implement → verify → create PR |
| **Ambiguous**   | Unclear scope, multiple interpretations           | Ask ONE clarifying question                                  |

### Step 2: Check for Ambiguity

| Situation                                       | Action                                           |
| ----------------------------------------------- | ------------------------------------------------ |
| Single valid interpretation                     | Proceed                                          |
| Multiple interpretations, similar effort        | Proceed with reasonable default, note assumption |
| Multiple interpretations, 2x+ effort difference | **MUST ask**                                     |
| Missing critical info (file, error, context)    | **MUST ask**                                     |
| User's design seems flawed or suboptimal        | **MUST raise concern** before implementing       |
| Script timeout (>2min), sudo needed, blocker    | **MUST ask** for help                            |

### Step 3: Validate Before Acting

- Check implicit assumptions that might affect the outcome
- Identify which tools, agents, and parallel/background execution best serve this request
- If user's design will cause problems or will contradict codebase patterns → raise concern, propose alternative, ask before proceeding
  </behavior-instructions>

<conventions>

## Conventions

- **Commit messages**: describe the actual change, not the trigger. "address review feedback" is banned — state what changed
- **GitHub CLI**: prefer `gh pr view`, `gh issue list`, `gh search prs` over `gh api`. Use `gh api` only when subcommands can't get the data
- **Commands in output**: must be copy-paste runnable, never abbreviated pseudocode
- **Research findings**: include steps another user can independently verify (exact commands + output)
- **New features**: iterate TDD-style (Red → Green → Refactor). Use `/tdd-integration` for strict cycle, `/superpowers:test-driven-development` before implementation

</conventions>

<first-principles-reimplementation>
When refactoring estimate exceeds 2x reimplementation effort (wrong language, heavy legacy
baggage, architectural mismatch) — prefer building from scratch. Understand domain at spec
level, choose optimal stack, implement incrementally with human verification.
</first-principles-reimplementation>

<constraint-persistence>
When user defines constraints ("never X", "always Y", "from now on"), immediately persist
to the appropriate CLAUDE.md (project-level for project-specific constraints, global for
general preferences). Acknowledge, write, confirm.
</constraint-persistence>

</principles>

<tools>

## Tools

<cli>

### CLI Tools (via Bash)

- **AST search/refactoring**: `ast-grep` — for structural search (classes, functions, patterns)
- **JSON processing**: `jq` — for complex transformations
- **YAML, TOML, CSV, CBOR, Avro, MessagePack, Protobuf processing**: `rq` — for complex transformations
- **Code search**: `rg` with flags (`-t`, `-g`, `--json`) — when specific output format needed

</cli>

<mcp-servers>

### MCP Servers

**Tool selection guide:**

| Need                          | Primary tool                                                | Fallback                  |
| ----------------------------- | ----------------------------------------------------------- | ------------------------- |
| Library docs / API references | `/context7`                                                 | `mcp__deepwiki`           |
| How a specific repo works     | `mcp__deepwiki`                                             | Agent(Explore)            |
| Real-world usage patterns     | `mcp__grep-app__searchGitHub`                               | —                         |
| Quick URL → markdown, no key  | `/markdown-new`                                             | `WebFetch`                |
| URL with selectors/auth/PDFs  | `mcp__jina__read_url`                                       | `/jina-reader` curl       |
| Web search                    | `mcp__jina__search_web` or `mcp__tavily-mcp__tavily_search` | `/tavily` curl            |
| Deep multi-step research      | `mcp__tavily-mcp__tavily_research`                          | `/jina-reader` DeepSearch |
| Site crawl / map              | `mcp__tavily-mcp__tavily_crawl`                             | `/tavily` curl            |

</mcp-servers>

</tools>

<code-structure>

## Code Structure

**File layout (top to bottom):**

1. Imports (follow project conventions, run formatter)
2. Constants
3. Types/interfaces
4. Main export (component/function)
5. Secondary exports
6. Internal helpers (small inline, large → separate utils file)

**Key principle:** Main export at the top — readers see the purpose immediately.

</code-structure>

</claude-instructions>
