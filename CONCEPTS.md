# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## herdr

### Child-agent contract
The agreement between a parent agent and child agents launched into sibling panes or their own `--tab`. Attached `--wait` keeps the result inside the current parent turn and arms no watcher. Managed `--detach` captures parent and child terminal/session identity, a fresh-state baseline, and a generation; an external per-child watcher then wakes the parent with generation-and-event markers for settlement, blockage, timeout, or unplanned disappearance. A child decision uses `ask`/`reply`; ordinary follow-ups use pair-addressed `prompt --wait|--detach`; reap invalidates supervision before pane closure and preserves sibling panes in a child-owned tab. Lifecycle settlement is a wake signal, not a task verdict. Markers and metadata coordinate cooperative same-user clients and are not authorization credentials.

### Sandbox-scoped takeover
A Herdr intervention that attaches the operator to an agent inside its existing microVM. It preserves the agent's filesystem, network, and credential boundaries and never falls back to a host shell.

## Theming

### Palette-only contract
The rule that TUI theme files managed by this repo (Claude Code, opencode, pi) reference the terminal's ANSI palette slots — indices 0–15, `ansi:` names, or "terminal default" — never baked hex, so every tool follows the terminal scheme automatically. Enforced syntactically by tests in `tests/bashunit/scripts_test.sh`; the terminal-theme-playground project is its visual counterpart ("eyes", not enforcement).

## Agent platform

### Explicit-only workflow
A workflow that interrupts the current task and must run only after a direct user request. Its shared description and instructions are packaged as a Claude Code skill with model invocation disabled, consumed by Pi through the shared Claude skill path, and exposed to OpenCode as a manual command rather than a native skill.
