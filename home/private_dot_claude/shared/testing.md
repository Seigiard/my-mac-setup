## Testing Rules

Reached from the testing pointer in `~/.claude/CLAUDE.md` and from the `tdd` skill.

### Declare the oracle first

- **Declare the oracle before the first test edit.** Before the first Edit/Write to any test file, write one line in your visible response naming the consumer, the observable failure, and an oracle independent of the files this patch changes. If you cannot complete the line, write zero new tests and say so. A useful test fails when the protected behavior breaks and stays green through harmless source refactors.
- **This gate outranks every skill's step list.** A "write failing tests first" step in any workflow does not waive it: a red test proves nothing when its expected value comes from the same patch or inspects source shape. Without the oracle line, the correct output of that step is zero tests.
- Reject expected values copied from source, prompt, config, fixture, or inventory changed by the same patch, and values *re-derived* by running the logic under test — the same formula, the same transform, the same helper the production path calls. Write the literal result the contract produces. When expectation and implementation share a source, the test is a false green: it stays green when both are wrong.

  ```typescript
  // tautological: the expectation is the implementation, restated
  const expected = items.reduce((sum, i) => sum + i.price, 0);
  expect(calculateTotal(items)).toBe(expected);

  // oracle: a literal the contract fixes
  expect(calculateTotal([{ price: 10 }, { price: 5 }])).toBe(15);
  ```
- **Editing a test is authoring it.** Changing expected values, renaming what a test calls, or porting it to a new API re-opens this gate: write the oracle line for the version you keep, or delete it and name the contract that goes uncovered.
- **A port is authored once per contract, not once per file.** A **port** is a test or fixture change where the data format or API shape changes and the rule the tests protect does not. The ported tests share one oracle line that names the contract and the literal it fixes in the new shape; every file that line covers is ported mechanically against it, and red before green is owed to that contract's owner test once, not to each ported file. A ported test whose expected value has to change for a reason the line does not give has found a contract change: it leaves the port and takes this gate on its own.

### Select checks before execution

- Before running checks, identify the affected behavior each check verifies.
- Reuse passing results while the state within their coverage is unchanged.
- If a mandatory check is irrelevant to the affected behavior, surface that conflict before running it and ask for a decision.

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

A **criterion** is one behavior the task asks for, and its **occurrence** is where that behavior was seen or requested: the ticket sentence, a report, a log line, or an incident. In the `tdd` chain they live in `ticket.md`; elsewhere the task's own request supplies them, and a path the request does not name has no criterion. A path gets a test through a criterion that names its occurrence and its oracle line; an error path, a boundary input, or an async state is covered when a criterion names it. One owner per behavior: a second test on the same contract is a variant only when its occurrence differs. A path with no independent oracle stays untested rather than getting a test that asserts its own patch back.

### Structure

- Mark the three phases with `// #given`, `// #when`, `// #then` comments, in that order
- One logical assertion per test
- Descriptive test names that explain the scenario

### Observe the contract

- **Verify through the interface.** Observe the result the way the consumer named in the oracle line would. A test that substitutes a database row, a private field, or a spy on an internal collaborator for that interface is **implementation-coupled**: it breaks on a refactor that changes no behavior, and it stays green when the interface lies. A database read is the interface only when the database itself is the contract the consumer reads.

  ```typescript
  // implementation-coupled: bypasses the interface to verify
  await createUser({ name: "Alice" });
  const row = await db.query("SELECT * FROM users WHERE name = ?", ["Alice"]);
  expect(row).toBeDefined();

  // contract: the caller's own path answers
  const user = await createUser({ name: "Alice" });
  expect((await getUser(user.id)).name).toBe("Alice");
  ```
- **Rendered text is behavior.** Pin a label or summary's format with one example, then assert the rules the text obeys — entries that read distinctly, each carrying its own record's fields, agreeing with the pipeline's own output.
- Keep exact text only for externally consumed literal contracts, and inventories only when they compare independent sides of a relationship.
- Behavior owned by an upstream system — a tool you route input to, a library you call — has no valid local oracle. Do not reimplement it locally to make it testable; route to its real interface and leave its semantics untested here.
- Removing a dependency, command, config entry, or file does not by itself justify an absence assertion. Test the capability that remains, or exercise the real deployment/runtime transition that clears stale state — never a source grep.

### Mocking

- Mock at **system boundaries** only: external APIs, time and randomness, and a database or file system when a real disposable one is unavailable. Your own modules, internal collaborators, and the unit under test run real: a mock there is implementation-coupled.
- Reset mocks between tests.
- A mock is one value, not a program: each mock returns one shape, and the test setup carries no branch. When the production change is yours to shape, design the boundary for that: pass the external client in (dependency injection) instead of constructing it inside the unit, and expose one function per external operation (`api.getUser(id)`, `api.createOrder(data)`) instead of one generic `api.fetch(endpoint, options)`. When it is not, mock the boundary as it stands and report the seam that forced a branching mock.
