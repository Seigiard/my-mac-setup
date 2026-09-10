---
paths: "**/*.{test,spec}.{ts,tsx,js,jsx,mjs,cjs}, **/__tests__/**, **/*_test.{sh,py,go,rb,ts,tsx}, **/test_*.py, **/*.bats, **/tests/**"
---

## Testing Rules

### Declare the oracle first

- **Declare the oracle before the first test edit.** Before the first Edit/Write to any test file, write one line in your visible response naming the consumer, the observable failure, and an oracle independent of the files this patch changes. If you cannot complete the line, write zero new tests and say so. A useful test fails when the protected behavior breaks and stays green through harmless source refactors.
- **This gate outranks every skill's step list.** A "write failing tests first" step in any workflow does not waive it: a red test proves nothing when its expected value comes from the same patch or inspects source shape. Without the oracle line, the correct output of that step is zero tests.
- Reject expected values copied from source, prompt, config, fixture, or inventory changed by the same patch. Prefer one behavioral, deployment, or validation owner; keep exact text only for externally consumed literal contracts and inventories only when they compare independent sides of a relationship.
- Behavior owned by an upstream system — a tool you route input to, a library you call — has no valid local oracle. Do not reimplement it locally to make it testable; route to its real interface and leave its semantics untested here.
- Removing a dependency, command, config entry, or file does not by itself justify an absence assertion. Test the capability that remains, or exercise the real deployment/runtime transition that clears stale state — never a source grep.

### Coverage

A unit is tested when its happy path, every error path it can produce, its empty/null/boundary inputs, and each async state (loading, success, error) all have a test. An untested error path means the work is not done. This does not override the oracle gate: a path with no independent oracle stays untested rather than getting a test that asserts its own patch back.

### Structure

- Mark the three phases with `// #given`, `// #when`, `// #then` comments, in that order
- One logical assertion per test
- Descriptive test names that explain the scenario

### Mocking

- Mock external dependencies (APIs, databases)
- Don't mock the unit under test
- Reset mocks between tests
