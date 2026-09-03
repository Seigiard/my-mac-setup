# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## herdr

### Child-agent contract
The agreement between a parent agent and child agents launched into sibling panes or their own `--tab`. `herdr-child` allocates each child a registered `color-animal` alias and returns it with the pane ID. Attached `--wait` keeps the result inside the current parent turn and arms no watcher. Managed `--detach` captures parent and child terminal/session identity, a fresh-state baseline, and a generation; an external per-child watcher then wakes the parent with generation-and-event markers for settlement, blockage, timeout, or unplanned disappearance. A child decision uses `ask`/`reply`; ordinary follow-ups use pair-addressed `prompt --wait|--detach`; reap requires the verified alias-plus-pane pair, invalidates supervision before pane closure, and preserves sibling panes in a child-owned tab. Lifecycle settlement is a wake signal, not a task verdict. Markers and metadata coordinate cooperative same-user clients and are not authorization credentials.

### Sandbox-scoped takeover
A Herdr intervention that attaches the operator to an agent inside its existing microVM. It preserves the agent's filesystem, network, and credential boundaries and never falls back to a host shell.

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
The rule that TUI theme files managed by this repo (Claude Code, opencode, pi) reference the terminal's ANSI palette slots — indices 0–15, `ansi:` names, or "terminal default" — never baked hex, so every tool follows the terminal scheme automatically. Enforced syntactically by tests in `tests/bashunit/scripts_test.sh`; the terminal-theme-playground project is its visual counterpart ("eyes", not enforcement).

## Agent platform

### Hooks core
The shared dispatch layer for agent-client hook policies (`~/.local/lib/agent-hooks/`). A policy is written once in the core and declared applicable per client and tool in a static registry; per-client adapters (Claude Code hook, OpenCode plugin, Pi extension) perform transport only — event normalization in, decision translation out. Decisions are `allow`, `block(reason)` with a `<policy-name>:` prefix, or `context(text)` (Claude-only). Every failure path fails open.

### Explicit-only workflow
A workflow that interrupts the current task and must run only after a direct user request. Its shared description and instructions are packaged as a Claude Code skill with model invocation disabled, consumed by Pi through the shared Claude skill path, and exposed to OpenCode as a manual command rather than a native skill.

## Testing

### Post-apply suite
The test suite that asserts against the already-deployed home directory rather than against the repository checkout. Each file in it declares its own run order and whether it is host-safe or needs a disposable home; a file that declares nothing fails the runner instead of being quietly skipped.

Because it reads deployed state, an edit made in the checkout but not yet applied is invisible to it. Proving such an edit requires the containerized run that applies the checkout first.

### Host-safe suite file
A post-apply suite file that executes no real deployment command, so it is safe to run against a developer's live home directory. Its complement needs a disposable home; running that complement without one is a configuration error, not a skip.

### Disposable home
An environment's explicit declaration that its home directory may be overwritten by real deployment commands. Only the declaration grants permission — being inside a container or on a continuous-integration runner never does, because a developer who exports a CI variable, or a long-lived development container holding real work, would otherwise receive a live overwrite.

The guard fails closed. An environment that looks like a runner but carries no declaration is reported as misconfigured rather than run or silently skipped.
