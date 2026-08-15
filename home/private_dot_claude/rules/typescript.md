---
paths: "**/*.{ts,tsx}"
---

## TypeScript Rules

Grep/Glob **locates**, LSP **understands**: find the file with Grep/Glob, then use `goToDefinition`, `findReferences`, and `hover` for definitions, call sites, and types instead of reading the file whole. Grep returns text matches; LSP returns exact ones.

### Naming Conventions

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

### Async/Await

- Every promise is awaited inside a `try/catch` or carries a `.catch` — no floating promises

### React Hooks

- Prefer derived values over state + effect patterns
- Use `useMemo` for expensive calculations, not `useEffect`
