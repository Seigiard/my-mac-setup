# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## se-pipeline

### se-pipeline
The durable, crash-safe pipeline that takes an implementation-ready plan through work, simplify, and verify stages as one resumable run, with human approval pauses at its gates.

### Run branch
The git branch a single se-pipeline run creates and commits to. Everything the run produces lands here; nothing merges without passing the run's gates.

### Staged worktree
An isolated checkout of the run branch that a run works in, separate from the operator's live checkout. External legs read repo content only from here.

### External leg
An independent run of an outside model dispatched by a stage (for review, simplify, or verification) that receives repo content and returns a structured report. Every external leg is an egress path and must sit behind the secret boundary.

### Secret boundary
The gate guaranteeing repo content is secret-scanned before it reaches any external leg. The scan covers the run's own commits only; a leak or a scanner failure closes the gate — only a clean scan opens it.

### Rescan
A repeat of the secret scan triggered when new commits appear after the last scan — whether the pipeline itself committed them or an operator did during a pause. Unknown prior scan state fails closed: the rescan runs rather than being skipped.

### Degraded
A gate outcome meaning the stage cannot vouch for its result — a finding, a tool failure, or an unverifiable state. Degraded parks the run for a human decision; it is distinct from failure, which stops the run outright.

### Waive
An operator's explicit approval that lets a run continue past a degraded gate, recorded with the finding it accepts. Waiving accepts a specific known result; it never disables the check for future runs.

### Flow spec
A declarative document describing a composed flow: which blocks run, how they link, and their parameters. The spec is data, not code — it is validated before launch, and varying it never changes the workflow's identity. A launched flow is frozen; recomposing means starting a new run.

### Block
A reusable unit of pipeline work (a scan, an agent run, a subflow) registered in a fixed catalog that the interpreter dispatches from. A flow spec composes blocks by reference; blocks declare their inputs, outputs, and gate behavior.

### Zero-in-flight rule
The delivery rule that workflow code — the interpreter, blocks, and shared libraries — is edited only when no run is live or parked. A durable engine ties each run's identity to that code, so editing it under an in-flight run breaks the run's resume; runs are drained or explicitly written off first.
