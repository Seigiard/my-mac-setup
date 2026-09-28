---
description: "efficiency — avoidable runtime work on evidenced paths: repeated calls, N+1, blocking hot paths, redundant updates, and excessive reads or retention"
---
## Lens: efficiency

Review changed runtime paths for avoidable work. `simplify` asks whether code needs to exist;
this lens asks what it costs when it runs. A smaller implementation can still do more work.

Apply only the checks whose surface the change touches:

- repeated computations, file reads, or network calls with the same inputs and no intervening
  change that requires them
- N+1 queries or calls inside loops, unbounded fetches, and reading a whole collection or file
  when the consumer needs only a bounded part
- blocking I/O or repeated expensive work on startup, request, render, or event-loop paths
- recurring polling, event, or reducer updates that do nothing but still trigger downstream
  work; check whether wrappers preserve the platform's no-change signal, such as object identity
- independent operations serialized despite a caller that waits for all of them; establish that
  ordering, side effects, rate limits, and resource limits permit concurrency before proposing it
- data retained after its last use, growing caches, and listeners or subscriptions that outlive
  their owner. Report a correctness defect once, naming `bugs` alongside this lens when applicable

Ground each candidate in a reachable path and an evidenced workload: input size, call frequency,
or a latency requirement from code, callers, project docs, or existing measurements. Trace the
amount of work and its concrete consequence. Distinguish a measured cost from an estimate; do not
invent timings or assume production scale from a loop alone.

Propose a fix only when it preserves outputs, errors, side effects, and required ordering. Account
for invalidation before proposing reuse or caching. Account for cancellation and peak resource use
before proposing concurrency.

Leave out speculative caching, cold-path micro-tuning, style preferences such as one loop syntax
over another, and scale the project does not expect. A missing optimization without an observable
cost is not a finding.

Each finding names the location, workload evidence, avoidable work, consequence, and concrete fix.
When no supported candidate remains, report no findings.
