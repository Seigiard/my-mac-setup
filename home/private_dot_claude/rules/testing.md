---
paths: "**/*.{test,spec}.{ts,tsx,js,jsx,mjs,cjs}, **/__tests__/**, **/*_test.{sh,py,go,rb,ts,tsx,exs}, **/*_spec.{rb,ts,js,lua}, **/test_*.py, **/*.bats, **/tests/**, **/test/**, **/spec/**"
---

## Testing Rules

### Declare the oracle first

- **Declare the oracle before the first test edit.** Before the first Edit/Write to any test file, write one line in your visible response naming the consumer, the observable failure, and an oracle independent of the files this patch changes. If you cannot complete the line, write zero new tests and say so. A useful test fails when the protected behavior breaks and stays green through harmless source refactors.
- **This gate outranks every skill's step list.** A "write failing tests first" step in any workflow does not waive it: a red test proves nothing when its expected value comes from the same patch or inspects source shape. Without the oracle line, the correct output of that step is zero tests.
- Reject expected values copied from source, prompt, config, fixture, or inventory changed by the same patch, and values *re-derived* by running the logic under test — the same formula, the same transform, the same helper the production path calls. Write the literal result the contract produces. When expectation and implementation share a source, the test is a false green: it stays green when both are wrong.
- Prefer one behavioral, deployment, or validation owner; keep exact text only for externally consumed literal contracts and inventories only when they compare independent sides of a relationship.
- Behavior owned by an upstream system — a tool you route input to, a library you call — has no valid local oracle. Do not reimplement it locally to make it testable; route to its real interface and leave its semantics untested here.
- Removing a dependency, command, config entry, or file does not by itself justify an absence assertion. Test the capability that remains, or exercise the real deployment/runtime transition that clears stale state — never a source grep.

### False green

A **false green** is a test that passes whether the behavior is right or wrong. It costs more than a missing test, because it looks like evidence and stops the next investigation. Every test you leave behind has to be able to go red:

- **Assert the exact value.** `toBe`/`toEqual`/`assert_equal` against the result you expect. A direction — greater than zero, truthy, defined, not null, a substring — leaves every other wrong result passing, and is warranted only where the surrounding output is genuinely unstable; then the text you do match must itself change when the behavior breaks.
- **Give a test one assertion path.** The same expectation every run, whatever the code does. A branch that picks between two expectations — `if`/`else`, `case`, a `catch` asserting an error instead, `|| true`, `set +e` — passes either way. Skip only on a named environment precondition, and leave the skip visible.
- **Assert status before output.** A command that failed still prints text an output assertion will accept.
- **Let the real boundary answer, never the stub.** A mock configured to return a value cannot then adjudicate that value. Its setup often sits far above the assertion, at the top of the file, so read the setup before trusting what follows. Import the unit under test; restating it in the test file makes the test its own subject.
- **Observe red before green.** A regression test is finished once you have seen it fail with the regression present, for the stated reason rather than on a setup error, and pass without it. A test observed only green is **uncalibrated**: report it that way rather than as coverage.

### A red test is a defect report

- Answer a red test by fixing the code, or by stating the defect and leaving the test red. Deleting, skipping, weakening, or narrowing it reaches green by removing the evidence instead of the defect.
- When new behavior legitimately changes a contract, say that the contract changed and write a fresh oracle line for the replacement assertion. "The test was outdated" is a claim that carries the same burden as a new test.
- Retire a test by naming the contract it covered and the test that now owns it. Without that name, the deletion is coverage loss dressed as cleanup.

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
