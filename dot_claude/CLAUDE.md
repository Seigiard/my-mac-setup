## Tools

### CLI tools (via Bash)
- **AST search/refactoring**: `ast-grep` — for structural search (classes, functions, patterns)
- **JSON/YAML processing**: `rq` — prefer over jq for complex transformations
- **Code search**: `rg` with flags (`-t`, `-g`, `--json`) — when specific output format needed

### MCP servers
- `grep` — search public GitHub repositories
- `context7` — library documentation and code generation

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
