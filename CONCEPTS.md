# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## se-pipeline

### se-pipeline
The durable, crash-safe pipeline that takes an implementation-ready plan through work, simplify, and verify stages as one resumable run, with human approval pauses at its gates.

### Run branch
The git branch a single se-pipeline run creates and commits to. Everything the run produces lands here; nothing merges without passing the run's gates.

### Staged worktree
An isolated checkout of the run branch that a run works in, separate from the operator's live checkout. External legs read repo content only from here. The run's frozen plan copy sits beside it, never inside it.

### Frozen plan copy
The run-local copy of the plan taken when the run stages its worktree, and the plan path a dispatched agent is given in place of the operator's own.

It lives beside the staged worktree rather than inside it, for two reasons that both bite: the run commits the agent's work with a whole-tree add, so a copy inside would land on the run branch, and it would also make the worktree's content differ from the base commit even for an agent leg that produced nothing — which would silently disable the proof of work. The copy is taken only from a source that still matches the hash the run recorded: a plan edited since then refuses the run rather than being frozen again, while a copy that drifted is simply rewritten from that verified source. It is deleted with the worktree, because it holds the plan's full text outside any repository.

### External leg
An independent run of an outside model dispatched by a stage (for review, simplify, or verification) that receives repo content and returns a structured report. Every external leg is an egress path and must sit behind the secret boundary.

A leg is healthy when its report parses and carries the findings it was asked for, and its status does not itself claim failure or an unfinished state. A missing, unparseable, or status-less report counts as a failed leg, never as an empty-but-clean one — but a status word the pipeline simply does not recognise is not failure evidence, because the payload is what proves the leg ran. A failed leg degrades the stage rather than silently shrinking review coverage.

### Dead leg
An external leg that stopped before producing its report — killed for silence, crashed, or cut off mid-review — whose danger is that it can still return something well-formed enough to be mistaken for a clean review with nothing to report. Detecting one is a distinct job from reading its findings, and it is the check that must never fail open.

### Finding
A single reviewable defect a leg reports, carrying a location, a description, and a severity. Severity is what gates act on: the most severe classes block, the rest are advisory. Findings from several legs are merged deterministically in code before any gate counts them, so a discarded leg does not merely lower confidence — its findings leave the merged report entirely.

### Secret boundary
The gate guaranteeing repo content is secret-scanned before it reaches any external leg. A leak or a scanner failure closes the gate — only a clean scan opens it.

It has two tiers, because what an external leg reads is larger than what a run writes. The **range tier** covers the run's own commits and answers "did this work add a secret". The **tree tier** covers the whole tree at the snapshot commit — the full checkout a leg is handed, including files committed on the base branch long before the run — and is the only tier that can see a secret the run never touched. The tree is exported from git rather than read off the live worktree, so build output and dependencies a run installed are not mistaken for repository content.

### Tree baseline
The per-repo record of what a repository's tree already looked like, which the tree tier judges against. It exists because a repo's own test fixtures and false positives are indistinguishable from leaks to a scanner, so an ungated tree scan refuses every run rather than protecting any. The first run for a repository captures the baseline and passes, saying loudly what it just made invisible; later runs refuse only on findings the baseline does not contain. A baseline is harness state, not repository content — it never lands inside the target repo, which belongs to other people and other agents.

### Boundary escape hatch
The operator's deliberate way past a closed boundary, and it differs by run shape. A pipeline run parks on an approval pause and the operator waives there. A harness run outside the pipeline has no pause to waive at, so it refuses and the operator re-launches with `SE_SKIP_SECRET_SCAN=1`, which skips both tiers. A caller that already applied the boundary says so (`preScanned`), so a waived pipeline scan is not overruled downstream.

### Rescan
A repeat of the secret scan triggered when new commits appear after the last scan — whether the pipeline itself committed them or an operator did during a pause. Unknown prior scan state fails closed: the rescan runs rather than being skipped.

### Gate
The check that closes a stage and decides whether the run may go on. A gate is a pure predicate over what the stage produced and over independently measured evidence — never over the stage's own self-report. Gates are the pipeline's decisions; the engine that executes them only knows whether the check ran.

### Proof of work
The evidence a gate uses to decide that an agent stage produced something, taken from the repository's content rather than from the agent's report: the staged worktree's tree is compared against the base commit's, and identical trees mean the stage produced nothing whatever the agent claimed.

It is content-based on purpose, so it is independent of how or when commits were arranged, and it holds only while nothing else writes into the worktree — which is why run-local files a run stages for itself live outside it.

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
