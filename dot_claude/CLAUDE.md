## Tools

Use `rq`, `ripgrep` and `ast-grep` when you need it.
Use `grep` MCP server that searches public GitHub repositories. Through the Grep MCP server, AI agents can issue search queries and retrieve code snippets that match specific patterns or regular expressions, filtered by language, repository, and file path
Use `context7` for code generation and library documentation.

ALWAYS when you done run the command `osascript -e 'display notification "$RELEVANT_MESSAGE" with title "$TITLE_DO_IDENTIFY_PROJECT"'`

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
