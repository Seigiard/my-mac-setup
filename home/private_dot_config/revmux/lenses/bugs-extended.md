---
description: "bugs supplement — sentinel meaning changes and setup/cleanup exit paths"
---
## Lens: bugs-extended

- When a sentinel gains a new meaning, trace consumers through rendering, metrics, and
  actions. `null`, an empty collection, or a fallback enum can stand for distinct states.
  Name the wrong result when a consumer cannot distinguish, for example, "empty" from
  "failed"; not crashing is not proof that the new state is handled correctly.
- For setup/cleanup changes, enumerate mutations on every exit path, including early
  returns and "already loaded" guards. Check each against its teardown or ownership
  transfer. On UI lifecycle changes, include cancellation, remounts, DOM/global mutations,
  and callbacks arriving after teardown.
