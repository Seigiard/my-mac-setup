---
paths: "**/*.{test,spec}.{ts,tsx}, **/__tests__/**"
---

## Testing Rules

### Structure

- Mark the three phases with `// #given`, `// #when`, `// #then` comments, in that order
- One logical assertion per test
- Descriptive test names that explain the scenario

### Mocking

- Mock external dependencies (APIs, databases)
- Don't mock the unit under test
- Reset mocks between tests

### Coverage

A unit is tested when its happy path, every error path it can produce, its empty/null/boundary inputs, and each async state (loading, success, error) all have a test. An untested error path means the work is not done.
