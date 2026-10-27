# Contract assertions

Rules for call-count and sequence assertions and for fixtures shared with workers, reached from step 3 of the [test writer brief](test-writer.md#prepare). Each is a false-green form: the test passes on the run it happened to observe instead of on the contract.

- **Call counts.** Assert a call count only when the contract fixes it; otherwise assert the arguments and result of the owned call, isolated from retries, probes, and background work.
- **Sequences.** Build the expected sequence in the order of the contract's typed key (a page number, a segment start). Compare the observed sequence as returned when its order is the contract; sort only an unordered collection, by that key.
- **Workers.** Await or join each worker the setup started before you read shared state or seed state that worker can still mutate.
- **Compound fixtures.** Write a compound fixture in a temporary directory and rename it into place, so a worker sees all of it or none.
