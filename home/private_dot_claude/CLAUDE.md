<claude-instructions>

<principles>

<epistemology>
Assumptions are the enemy. Never guess numerical values - benchmark instead of estimating.
When uncertain, measure. Say "this needs to be measured" rather than inventing statistics.
</epistemology>

<interaction>
Clarify unclear requests, then proceed autonomously. Only ask for help when scripts timeout
(>2min), sudo is needed, or genuine blockers arise.
</interaction>

<ground-truth-clarification>
For non-trivial tasks, reach ground truth understanding before coding. Simple tasks execute
immediately. Complex tasks (refactors, new features, ambiguous requirements) require
clarification first: research codebase, ask targeted questions, confirm understanding,
persist the plan, then execute autonomously.
</ground-truth-clarification>

<first-principles-reimplementation>
Building from scratch can beat adapting legacy code when implementations are in wrong
languages, carry historical baggage, or need architectural rewrites. Understand domain
at spec level, choose optimal stack, implement incrementally with human verification.
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

**context7** — library documentation and code examples

- When: need official docs for a library/framework (React, Next.js, Prisma, etc.)
- Use for: API references, usage patterns, configuration options
- Flow: `resolve-library-id` → `query-docs`

**deepwiki** — GitHub repository analysis

- When: need to understand a specific open-source project's architecture
- Use for: how a repo works internally, design decisions, codebase structure
- Best for: "How does X implement Y?" questions about specific repos

**grep** — search public GitHub repositories

- When: need real-world code examples and usage patterns
- Use for: how developers actually use an API in production code
- Best for: finding implementation patterns across many projects

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

<code-comments>

## Code Comments

Keep comments minimal and meaningful. Only add comments that provide value.

<avoid>
- Comments that simply describe what the next line does (e.g., `// Check if user exists`)
- Comments that restate the code in plain English
- JSDoc comments that only describe a function's obvious purpose (e.g., `/** Renders the button component */`)
- Comments related to changes being made (e.g., `// Refactored to use new pattern`)
</avoid>

<include>
- Comments explaining _why_ a non-obvious decision was made
- Comments about intentional omissions or edge cases (e.g., `// Intentionally omitted X because Y`)
- Comments explaining workarounds or compatibility considerations
- Comments about complex business logic that isn't self-evident from the code
</include>

</code-comments>

</claude-instructions>
