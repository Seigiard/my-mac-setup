# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## herdr

### Child-agent contract
The agreement between a parent agent and child agents launched into sibling panes or their own `--tab`. `herdr-child` allocates each child a registered `color-animal` alias and returns it with the pane ID. Attached `--wait` keeps the result inside the current parent turn and arms no watcher. Managed `--detach` captures parent and child terminal/session identity, a fresh-state baseline, and a generation; an external per-child watcher then wakes the parent with generation-and-event markers for settlement, blockage, timeout, or unplanned disappearance. A child decision uses `ask`/`reply`; ordinary follow-ups use pair-addressed `prompt --wait|--detach`; reap requires the verified alias-plus-pane pair, invalidates supervision before pane closure, and preserves sibling panes in a child-owned tab. Lifecycle settlement is a wake signal, not a task verdict. Markers and metadata coordinate cooperative same-user clients and are not authorization credentials.

### herdr-worktree-identity
The component that derives a task title and multi-word branch slug from a generated worktree session's prompt, renames the authorized branch once with attribution, and labels the workspace. The alias system exclusively owns pane, tab, and agent identity. A contended claim writes a diagnostic but has no terminal outcome, so the next naming event retries it.

### Generated-worktree marker
The marker file the worktree-setup plugin writes into a worktree's git per-worktree admin dir on `worktree.created`. It is the sole authorization boundary for automated ref mutation in that worktree: a component may rename the generated branch only when the marker is present and matches — branch name text alone never authorizes. Later lines appended to the marker carry attribution for mutations already made.

### Workspace-only outcome
A terminal worktree-identity outcome in which the herdr workspace receives its task-derived title but the branch is left untouched, because the branch is no longer eligible for renaming (upstream set, moved by an agent, or a prior rename was reverted). Workspace labeling is decoupled from branch eligibility by design; the outcome is final, not a retry state.

### Detached worker
A background process a component forks so its caller can return immediately. Detachment has two halves and both are load-bearing: the worker takes its own session, and it closes every file descriptor it inherited above standard error.

Holding an inherited descriptor keeps the caller's reader — an agent harness, a test runner — waiting on an end-of-file that never arrives, which surfaces as a silent stall rather than a failure. The closure runs inside the worker once its arguments validate, never in the forking shell, which still needs its own descriptors to reach the exec. Every wait a detached worker performs carries an exit for abandonment — its owner gone, the state directory it depends on removed, or an absolute bound — and not only an exit for success.

## Theming

### Palette-only contract
The rule that TUI theme files managed by this repo (Claude Code, opencode, pi) reference the terminal's ANSI palette slots — indices 0–15, `ansi:` names, or "terminal default" — never baked hex, so every tool follows the terminal scheme automatically. Enforced syntactically by the test suite; the terminal-theme-playground project is its visual counterpart ("eyes", not enforcement).

## Agent platform

### Hooks core
The shared dispatch layer for agent-client hook policies. A policy is written once in the core and declared applicable per client and tool in a static registry; per-client adapters (Claude Code hook, OpenCode plugin, Pi extension) perform transport only — event normalization in, decision translation out. Decisions are `allow`, `block(reason)` with a `<policy-name>:` prefix, or `context(text)` (Claude-only). Every failure path fails open.

### Focused handoff
A handoff built relative to the goal the next session must finish, rather than a summary of the session that produced it. It is extracted before compaction destroys the thread, by a separate cheap model that reads the full pre-compact session and keeps only what serves that goal — so decisions, rejected approaches, and verification state survive in proportion to their usefulness ahead, not their volume behind.

Delivery is the half that silently fails. A handoff rendered to the operator's screen has not been handed off: only the hook field that injects into model context completes the transfer, and the two fields are easy to confuse because both surface text somewhere.

### External leg
A single review or analysis pass executed by a separate, headless agent-CLI process that returns a report and nothing else. A leg is a subprocess, not a collaborator: it can die silently, return partially, or return a well-formed report describing work it never did, so its output is judged by payload rather than by any status word it reports about itself. Absence of a well-formed result is failure, never a clean pass.

One failed leg degrades a review's coverage; losing every leg fails it.

### Blast-radius bias
The rule that a gate's default answer under uncertainty is set by what a wrong answer costs, not by where the gate sits. A gate in front of something that mutates code, spends money, or publishes outside the run defaults to refusing; a gate in front of a read-only or advisory step defaults to running, because a false refusal there silently removes coverage. The bias belongs to the whole gate stack — a fuzzy fallback layer inherits the deterministic layer's default — and a biased refusal is always stated, never silent.

### Explicit-only workflow
A workflow that interrupts the current task and must run only after a direct user request. Its shared description and instructions are packaged as a Claude Code skill with model invocation disabled, consumed by Pi through the shared Claude skill path, and exposed to OpenCode as a manual command rather than a native skill.

## Testing

### Semantic regression test
A test whose verdict depends on the behavior it protects rather than on the shape of the source that implements it. It goes red when the protected behavior breaks and stays green through a harmless refactor — which a test that greps source text, or asserts a string the same change introduced, cannot do.

Its expected value comes from somewhere the change under test does not control. Asserting the absence of something a patch just removed is the common failure: it restates the patch instead of protecting anything. A rejection fixture is paired with a nearby valid control, so the suite proves it can still reach the success path it claims to exercise.

### Test oracle
The independent source a test draws its expected value from. An oracle is valid only if it is outside the files the change under test edits — a real consumer, a deployment path, a published contract. When no such source can be named, the correct number of new tests is zero; behavior owned by an upstream tool or library has no valid local oracle and is exercised through its real interface rather than reimplemented to be testable.

### Hang guard
A deadline whose only job is to stop a run that has stopped making progress. It is deliberately generous and must never fire on a healthy run, which is what separates it from a behavioral assertion — a narrow bound that is itself the thing being proven. One number cannot be both: a deadline that doubles as an assertion either flakes under load or, once widened enough to stop flaking, no longer catches the regression it was written for.

A bound calibrated on an idle machine is a latent flake, because the contention profile a full parallel suite creates is not the one it was measured against. Where an ordering or concurrency property can be proven by a barrier, a marker, or another causal signal, that signal replaces elapsed time entirely.

### Skip-set parity
The proof that a reduced dependency set did not reduce coverage: the set of skipped tests, compared by identity, is unchanged between the two configurations. A green suite is not that proof, because a missing tool skips rather than fails, so a run can go green having silently stopped exercising whole files. Counts are not that proof either, since one skip swapped for another leaves the count intact.

When a dependency leaves the set, its absence is asserted rather than left unasserted, so a later silent re-add cannot pass.

### Bats-compatible test vocabulary
The assertion and capture surface the suites are written against — `run`, `$status`, `$lines`, the `assert_*` and `refute_*` helpers, per-test temporary directories — retained deliberately after the suite moved off the bats runner. It is a vocabulary, not a runner: the current runner reimplements these semantics on the same interpreter, which is why it also reproduces the interpreter's quirks, including the one where a bare mid-test compound conditional evaluates false without failing the test.

### Post-apply suite
The test suite that asserts against the already-deployed home directory rather than against the repository checkout. Each file in it declares its own run order and whether it is host-safe or needs a disposable home; a file that declares nothing fails the runner instead of being quietly skipped.

Because it reads deployed state, an edit made in the checkout but not yet applied is invisible to it. Proving such an edit requires the containerized run that applies the checkout first.

### Host-safe suite file
A post-apply suite file that executes no real deployment command, so it is safe to run against a developer's live home directory. Its complement needs a disposable home; running that complement without one is a configuration error, not a skip.

### Disposable home
An environment's explicit declaration that its home directory may be overwritten by real deployment commands. Only the declaration grants permission — being inside a container or on a continuous-integration runner never does, because a developer who exports a CI variable, or a long-lived development container holding real work, would otherwise receive a live overwrite.

The guard fails closed. An environment that looks like a runner but carries no declaration is reported as misconfigured rather than run or silently skipped.

## Retired

### Sandbox-scoped takeover
An operator intervention that would attach a human to a running agent inside its own microVM, preserving the agent's filesystem, network, and credential boundaries instead of dropping to a host shell. The project never had it: the only design that specified it deferred it to upstream support that did not arrive, and the execution engine that design targeted was removed.
