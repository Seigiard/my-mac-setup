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
