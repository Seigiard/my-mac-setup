---
description: correctness defects — logic and boundaries, nil and bounds, concurrency, resource lifetime, error handling
---
## Lens: bugs

Hunt for code that does the wrong thing when it runs. Read the changed code and the code that calls
it; a defect is often only visible from the caller's side.

Look for:

- logic that is inverted, off by one, or wrong at the boundary — empty input, a single element, the
  last iteration, the zero value
- nil or missing values dereferenced on a path that can actually produce them
- a sentinel gaining a new meaning: `null`, an empty collection, or a fallback enum now stands for
  distinct states. Trace consumers through rendering, metrics, and actions. Name the wrong result
  when a consumer cannot distinguish, for example, "empty" from "failed"; not crashing is not proof
  that the new state is handled correctly
- concurrency: state shared without synchronization, a lock not released on every return, a channel
  that can block forever, a goroutine outliving what it writes to
- resources acquired and not released on the error path — files, connections, timers, contexts
- setup/cleanup asymmetry: enumerate mutations on every exit path, including early returns and
  "already loaded" guards, and check each against its teardown or ownership transfer. On UI lifecycle
  changes, include cancellation, remounts, DOM/global mutations, and callbacks arriving after teardown
- errors dropped, swallowed, or returned without the context needed to act on them
- an error path that leaves state half-updated
- state persisting between calls where the caller assumes it does not

For each candidate, name the input or sequence that triggers it before you report it. If you cannot
produce one, you have found a smell rather than a bug — leave it out.
