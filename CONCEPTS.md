# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## herdr

### Child-agent contract
The agreement between a parent agent and child agents launched into sibling panes or their own `--tab`. `herdr-child` allocates each child a registered `color-animal` alias and returns it with the pane ID. Attached `--wait` keeps the result inside the current parent turn and arms no watcher. Managed `--detach` captures parent and child terminal/session identity, a fresh-state baseline, and a generation; an external per-child watcher then wakes the parent with generation-and-event markers for settlement, blockage, timeout, or unplanned disappearance. A child decision uses `ask`/`reply`; ordinary follow-ups use pair-addressed `prompt --wait|--detach`; reap requires the verified alias-plus-pane pair, invalidates supervision before pane closure, and preserves sibling panes in a child-owned tab. Lifecycle settlement is a wake signal, not a task verdict. Markers and metadata coordinate cooperative same-user clients and are not authorization credentials.

### herdr-worktree-identity
The component that derives one multi-word branch name from a generated worktree session's prompt, renames the authorized branch once with attribution, and gives the workspace the same final name. The alias system exclusively owns pane, tab, and agent identity. A contended claim writes a diagnostic but has no terminal outcome, so the next naming event retries it.

### Generated-worktree marker
The marker file the worktree-setup plugin writes into a worktree's git per-worktree admin dir on `worktree.created`. It is the sole authorization boundary for automated ref mutation in that worktree: a component may rename the generated branch only when the marker is present and matches — branch name text alone never authorizes. Later lines appended to the marker carry attribution for mutations already made.

### Workspace-only outcome
A terminal worktree-identity outcome in which the Herdr workspace receives the derived normalized branch name but the Git branch is left untouched, because the branch is no longer eligible for renaming (upstream set, moved by an agent, or a prior rename was reverted). Workspace labeling is decoupled from branch eligibility by design; the outcome is final, not a retry state.

### Detached worker
A background process a component forks so its caller can return immediately. Detachment has two halves and both are load-bearing: the worker takes its own session, and it closes every file descriptor it inherited above standard error.

Holding an inherited descriptor keeps the caller's reader — an agent harness, a test runner — waiting on an end-of-file that never arrives, which surfaces as a silent stall rather than a failure. The closure runs inside the worker once its arguments validate, never in the forking shell, which still needs its own descriptors to reach the exec. Every wait a detached worker performs carries an exit for abandonment — its owner gone, the state directory it depends on removed, or an absolute bound — and not only an exit for success.

### Command palette
A Herdr plugin that opens an overlay pane listing declared commands and runs the one the user picks.

Nothing in it is discovered. Its rows are hand-written configuration merged from a global set and a project-local set found by walking up from the invoking pane's working directory, so a capability appears in the palette only because someone declared it there — the usual assumption that a palette enumerates what an application can do is false here. It is reached by keybinding, dispatched as a plugin action rather than called directly. It is a singleton identified by a token on its own pane, so a second open focuses the existing one, and a pane that merely holds its source file open is not it. When its fuzzy-finder dependency is absent it refuses to start rather than degrading, because a silent fallback would hide a broken deployment.

### Palette command
One row inside the command palette: a title, a group, an origin, and a kind that decides how the row executes.

A command is declared in the palette's own configuration, never in a plugin manifest, and one of its kinds dispatches a plugin action — so the two nest, and "add an action to the palette" is ambiguous until the speaker says which they mean. A command that offers choices may take them from statically declared options or by running a command at invocation time and reading its output lines, under a timeout. Dynamically sourced *actions* do not exist: the palette never enumerates what other plugins expose.

### Plugin action
An entry point a plugin declares in its manifest, addressed by plugin id and action id, which Herdr dispatches in response to a keybinding or an explicit invocation.

Actions are the surface Herdr itself knows about, and a plugin declares a small fixed set of them. A palette command is not an action; it is a row that may dispatch one.

### Plugin registry
The record of which plugins a Herdr server has, keyed by plugin id.

It stores each plugin's root path rather than a copy, so deleting the linked directory leaves the entry visible while stripping its actions from resolution — the breakage surfaces at keypress, not at registration. Registration is addressed by socket rather than by home directory, and that is the trap: a link command run against a redirected home still mutates the live server's registry, so isolating one means clearing the environment rather than repointing home. A manifest change reaches the server only by re-linking, which validates the new manifest before replacing the existing registration in place, so no unlink-first window is needed. Enabling or disabling a plugin only flips a flag, and reloading configuration does not touch the registry at all.

## Theming

### Palette-only contract
The rule that TUI theme files managed by this repo (Claude Code, opencode, pi) reference the terminal's ANSI palette slots — indices 0–15, `ansi:` names, or "terminal default" — never baked hex, so every tool follows the terminal scheme automatically. The "palette" here is the terminal's colour table and is unrelated to the Command palette. Enforced syntactically by the test suite; the terminal-theme-playground project is its visual counterpart ("eyes", not enforcement).

## Agent platform

### Hooks core
The shared dispatch layer for agent-client hook policies. A policy is written once in the core and declared applicable per client and tool in a static registry; per-client adapters (Claude Code hook, OpenCode plugin, Pi extension) perform transport only — event normalization in, decision translation out. Decisions are `allow`, `block(reason)` with a `<policy-name>:` prefix, or `context(text)` (Claude-only). Every failure path fails open.

### Focused handoff
A handoff built relative to the goal the next session must finish, rather than a summary of the session that produced it. It is extracted before compaction destroys the thread, by a separate cheap model that reads the full pre-compact session and keeps only what serves that goal — so decisions, rejected approaches, and verification state survive in proportion to their usefulness ahead, not their volume behind.

Delivery is the half that silently fails. A handoff rendered to the operator's screen has not been handed off: only the hook field that injects into model context completes the transfer, and the two fields are easy to confuse because both surface text somewhere.

### External leg
A single review or analysis pass executed by a separate, headless agent-CLI process that returns a report and nothing else. A leg is a subprocess, not a collaborator: it can die silently, return partially, or return a well-formed report describing work it never did, so its output is judged by payload rather than by any status word it reports about itself. Absence of a well-formed result is failure, never a clean pass.

One failed leg degrades a review's coverage; losing every leg fails it.

### External leg pair
Two fresh External legs given the same review scope through separate agents and classified together. The pair provides paired coverage only when both reports are independently attributable, valid, and distinct; one failed or invalid leg degrades it to single-source coverage, as does a byte-identical pair. Pair classification describes coverage, never agreement or corroboration between findings.

### Captured child
A subprocess whose output the caller captures instead of passing through, which makes the caller responsible for the child's input as well. Capturing is itself what hides a prompt: the question renders into a buffer nobody is reading while the child waits on an input channel it still holds. So a captured child is denied that channel, and a flag or environment variable asking the child not to prompt counts as a request the callee may decline, never as the guarantee.

Denial applies only where nobody is watching; an attended path keeps the child interactive so a person can answer. The wait is bounded and terminates the child's whole process tree, reporting a status that distinguishes termination from the child's own failure, and progress output is emitted only when the caller's error stream is a terminal, so scripted callers stay silent. Because denial converts a possible hang into a certain failure, what that failure means is designed rather than inherited: a path that can no longer ask must report what it could not do, not produce a plausible answer without it.

### Protected slot
A reserved position in a report or envelope where a machine-readable signal is the only thing that may appear, so the same text occurring anywhere in the body is inert.

Extraction reads the position, never a scan of the document, which is what makes a quoted example or a code block in the body unable to promote itself into a verdict. The slot's value is cross-checked against the findings it claims to summarize, because a report can carry a signal its own content does not support. When the slot is absent or unparseable the layer built on it degrades to advisory rather than inventing a value — while the separate question of whether the report arrived at all stays fail-closed.

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

### Upstream fake
A test double that reproduces the observable contract of a program this project does not own — a stub CLI, a replayed protocol, a fixture standing in for another tool's output format. It is a claim about that program rather than about this one, so no assertion written beside it can adjudicate it; only the program itself can, through a conformance check that compares the two in the same run.

A fake records which release of the original it emulates, read from the original rather than assumed. Its conformance check pins the boundary the local consumer actually reads and stops there, because a deeper comparison restates a shape the upstream program owns — the same failure at a finer grain. Where the original is unreachable the check skips, naming which oracle is missing, never falling back to a locally invented expected value. Where the two diverge below the pinned boundary, that divergence is recorded as unresolved work rather than encoded into the check.

### Causal assertion
A test that proves an ordering or concurrency property from a signal the property itself produces — a barrier every party must reach, a marker one side writes and the other reads — instead of from how long a step took.

It is the preferred form wherever the property admits one, because elapsed time only correlates with the property while the machine behaves. A causal signal also settles non-vacuity: a bound nothing can ever exceed asserts nothing, and only a signal tied to the property can show the assertion window was reachable at all. Where no causal signal exists, what remains is a Hang guard, and the run should say so rather than let a deadline pass for a proof.

### Hang guard
A deadline whose only job is to stop a run that has stopped making progress, in a test suite or in shipped code that waits on a subprocess. It is deliberately generous and must never fire on a healthy run, which is what separates it from a behavioral assertion — a narrow bound that is itself the thing being proven. One number cannot be both: a deadline that doubles as an assertion either flakes under load or, once widened enough to stop flaking, no longer catches the regression it was written for.

A bound calibrated on an idle machine is a latent flake, because the contention profile a full parallel suite creates is not the one it was measured against. Where an ordering or concurrency property can be proven by a barrier, a marker, or another causal signal, that signal replaces elapsed time entirely. A guard is a deadline, never a Poll interval; a loop that conflates the two cannot be sped up without being weakened. A bound that crosses a process boundary is shared only if the consumer actually reads it: where the producer also derives a second bound from that value, an ignored hand-off moves the derived bound alone, and the pair drifts apart in the direction that makes the derived one vacuous.

### Poll interval
The rate at which a wait loop re-checks its condition, held as a separate overridable value from the deadline that ends the wait. The deadline is measured from elapsed time, so it holds however often the loop wakes.

Keeping them separate is what lets a test sample faster without moving the bound it asserts — shortening the interval is free, shortening the deadline changes what the test proves. A loop that decides expiry by counting its own iterations has fused the two: the sleep length becomes the clock, so every test that exercises the loop pays the production interval, and the cheapest available speedup is also a silent reduction in coverage. At least one test stays on the real interval, so the timeout path itself remains exercised.

### Differential equivalence proof
The evidence that a rewrite preserves behavior: its output compared against the previous implementation's, over a generated corpus, before the suite is consulted. The suite is the gate, not the proof — it asks whether anything a test pins changed, while the claim being made is that nothing changed at all.

The corpus is built from the ways this particular rewrite could differ rather than from generic inputs, so each category names a suspected divergence — an encoding that wraps above a length threshold, a delimiter appearing inside a value, a file without a trailing newline. The proof is normally throwaway, because keeping it runnable means keeping the replaced implementation alive to diff against; that trade is recorded rather than assumed, since it decides whether a later reader can re-check the claim or only read it.

### Skip-set parity
The proof that a reduced dependency set did not reduce coverage: the set of skipped tests, compared by identity, is unchanged between the two configurations. A green suite is not that proof, because a missing tool skips rather than fails, so a run can go green having silently stopped exercising whole files. Counts are not that proof either, since one skip swapped for another leaves the count intact.

When a dependency leaves the set, its absence is asserted rather than left unasserted, so a later silent re-add cannot pass.

### Bats-compatible test vocabulary
The assertion and capture surface the suites are written against — `run`, `$status`, `$lines`, the `assert_*` and `refute_*` helpers, per-test temporary directories — retained deliberately after the suite moved off the bats runner. It is a vocabulary, not a runner: the current runner reimplements these semantics on the same interpreter, which is why it also reproduces the interpreter's quirks, including the one where a bare mid-test compound conditional evaluates false without failing the test.

The historical test numbers carried across from the bats suites are metadata, not identity: they repeat once suites are merged, so anything that must be unique per test is keyed on the current runner's own per-test identity instead.

### Post-apply suite
The test suite that asserts against the already-deployed home directory rather than against the repository checkout. Each file in it declares its own run order and whether it is host-safe or needs a disposable home; a file that declares nothing fails the runner instead of being quietly skipped.

Because it reads deployed state, an edit made in the checkout but not yet applied is invisible to it. Proving such an edit requires the containerized run that applies the checkout first.

### Host-safe suite file
A post-apply suite file that executes no real deployment command, so it is safe to run against a developer's live home directory. Its complement needs a disposable home; running that complement without one is a configuration error, not a skip.

### Disposable home
An environment's explicit declaration that its home directory may be overwritten by real deployment commands. Only the declaration grants permission — being inside a container or on a continuous-integration runner never does, because a developer who exports a CI variable, or a long-lived development container holding real work, would otherwise receive a live overwrite.

The guard fails closed. An environment that looks like a runner but carries no declaration is reported as misconfigured rather than run or silently skipped.

### Unattended chezmoi mode
The repository-owned execution contract selected by `MMS_CHEZMOI_UNATTENDED=1` for agent, continuous-integration, and test invocations of chezmoi. Its explicit full-fixture profile requires disposable-home authority and renders credential-sensitive targets with non-secret canaries; its host-partial profile omits those targets from comparison and names what was not checked. Both profiles prevent interactive credential access before a helper subprocess starts and preserve the ordinary `PATH`.

Because the host-partial profile names its surviving targets explicitly, its comparison is delivered across as many chezmoi invocations as an argument-size budget allows rather than assumed to fit in one, and a single target too large for an empty budget aborts the run instead of being sent. The budget exists because chezmoi re-exports its whole invocation as one environment string to every template subprocess it spawns, where the operating system's per-string limit — not its total argument limit — applies.

## Flagged ambiguities

- "palette" carried three unrelated readings. The **Command palette** is Herdr's overlay launcher; the **Palette-only contract** concerns the terminal's ANSI colour table. Inline `# palette:` comments inside terminal-emulator configuration belong to the first sense — they are a hint format the palette parses to render its keybinding panel, not a colour declaration.
- "action" and "command" were used interchangeably for palette entries — these are distinct. A **Plugin action** is declared in a manifest and dispatched by Herdr; a **Palette command** is a row in the palette's own configuration, and only some kinds of row reach an action.

## Retired

### Sandbox-scoped takeover
An operator intervention that would attach a human to a running agent inside its own microVM, preserving the agent's filesystem, network, and credential boundaries instead of dropping to a host shell. The project never had it: the only design that specified it deferred it to upstream support that did not arrive, and the execution engine that design targeted was removed.
