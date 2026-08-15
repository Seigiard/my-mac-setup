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

A leg is healthy only when it returns a well-formed report with a terminal status; a missing, unparseable, or non-terminal report counts as a failed leg, never as an empty-but-clean one. A failed leg degrades the stage rather than silently shrinking review coverage.

### Secret boundary
The gate guaranteeing repo content is secret-scanned before it reaches any external leg. The scan covers the run's own commits only; a leak or a scanner failure closes the gate — only a clean scan opens it.

A harness run outside the pipeline enforces the same boundary itself, over the snapshot it is about to stage, and refuses the run instead of parking it — a standalone run has no approval pause to waive at. Its escape hatch is the operator setting `SE_SKIP_SECRET_SCAN=1` on the launch command. A caller that already scanned the range says so (`preScanned`), so a waived pipeline scan is not overruled downstream.

### Rescan
A repeat of the secret scan triggered when new commits appear after the last scan — whether the pipeline itself committed them or an operator did during a pause. Unknown prior scan state fails closed: the rescan runs rather than being skipped.

### Gate
The check that closes a stage and decides whether the run may go on. A gate is a pure predicate over what the stage produced and over independently measured evidence — never over the stage's own self-report. Gates are the pipeline's decisions; the engine that executes them only knows whether the check ran.

### Verdict
A gate's decision — green, failed, or degraded — together with the reasons that produced it. A verdict is distinct from a node having finished: a gate that decides against the run still completes normally, so a runner's completion signal says nothing about which way the gate went. Every non-green verdict parks the run and must be shown to the operator, with its reasons, wherever they act on it.

### Degraded
A gate outcome meaning the stage cannot vouch for its result — a finding, a tool failure, or an unverifiable state. It is distinct from failure, which means the stage's contract was broken outright; both park the run for a human decision rather than ending it.

### Approval pause
The stop a non-green verdict creates, where the run waits for an operator. What the operator's approval *does* is gate-specific, not universal — it may waive the finding and continue, buy one more paid attempt of the same stage, or stop the run with a report — so each pause states the effect of every available response rather than relying on the word "approve".

### Waive
An operator's explicit approval that lets a run continue past a degraded gate, recorded with the finding it accepts. Waiving accepts a specific known result; it never disables the check for future runs.

### Flow spec
A declarative document describing a composed flow: which blocks run, how they link, and their parameters. The spec is data, not code — it is validated before launch, and varying it never changes the workflow's identity. A launched flow is frozen; recomposing means starting a new run.

### Block
A reusable unit of pipeline work (a scan, an agent run, a subflow) registered in a fixed catalog that the interpreter dispatches from. A flow spec composes blocks by reference; blocks declare their inputs, outputs, and gate behavior.

### Zero-in-flight rule
The delivery rule that workflow code — the interpreter, blocks, and shared libraries — is edited only when no run is live or parked. A durable engine ties each run's identity to that code, so editing it under an in-flight run breaks the run's resume; runs are drained or explicitly written off first.
