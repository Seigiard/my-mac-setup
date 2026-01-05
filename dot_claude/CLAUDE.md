## Tools

### CLI tools (via Bash)
- **AST search/refactoring**: `ast-grep` — for structural search (classes, functions, patterns)
- **JSON/YAML processing**: `rq` — prefer over jq for complex transformations
- **Code search**: `rg` with flags (`-t`, `-g`, `--json`) — when specific output format needed

### MCP servers

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

### Notifications
After completing a task:
```bash
osascript -e 'display notification "MESSAGE" with title "PROJECT"'
```

## Code Comments

Keep comments minimal and meaningful. Only add comments that provide value.

**DO NOT add:**

- Comments that simply describe what the next line does (e.g., `// Check if user exists`)
- Comments that restate the code in plain English
- JSDoc comments that only describe a function's obvious purpose (e.g., `/** Renders the button component */`)
- Comments related to changes being made (e.g., `// Refactored to use new pattern`)

**DO add:**

- Comments explaining _why_ a non-obvious decision was made
- Comments about intentional omissions or edge cases (e.g., `// Intentionally omitted X because Y`)
- Comments explaining workarounds or compatibility considerations
- Comments about complex business logic that isn't self-evident from the code

## Git Commits

Propose to use `/gc` command to generate commit messages.
