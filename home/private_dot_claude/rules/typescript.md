---
paths: "**/*.{ts,tsx}"
---

## TypeScript Rules

When tracing where a symbol is defined or finding all references to it, use LSP (goToDefinition, findReferences, hover) instead of Grep. LSP gives exact results; Grep gives text matches.

Use Grep/Glob for discovery (finding files, searching patterns). Use LSP for understanding (definitions, references, type info).

After locating a file with Grep/Glob, use LSP to navigate within it rather than reading the whole file.

### Naming Conventions

- PascalCase for interfaces, types, classes, components
- camelCase for functions, variables, methods
- SCREAMING_SNAKE_CASE for constants
- kebab-case for file names

### Type Safety

- NO `any` without explicit justification comment
- NO `@ts-ignore` or `@ts-expect-error` without explanation
- Prefer `unknown` over `any` when type is truly unknown
- Use explicit return types on exported functions

### File Layout (top to bottom)

1. Imports (external → internal → relative)
2. Constants
3. Types/interfaces
4. Main export (component/function)
5. Secondary exports
6. Internal helpers (small inline, large → separate utils file)

Main export at the top — readers see the purpose immediately.

### Imports

- Use named exports over default exports
- No circular dependencies

### Async/Await

- Always handle promise rejections
- Use try/catch for async operations
- Avoid floating promises (unhandled)

### React Best Practices

- When writing React code, invoke `react-best-practices` skill
- Verify all changes using `react-doctor` skill

### React Hooks

- When writing or reviewing `useEffect` or `useState` for derived values, invoke `react-useeffect` skill
- Prefer derived values over state + effect patterns
- Use `useMemo` for expensive calculations, not `useEffect`
