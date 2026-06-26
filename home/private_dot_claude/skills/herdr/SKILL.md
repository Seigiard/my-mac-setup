---
name: herdr
description: "Control herdr from inside it: manage workspaces, tabs, and panes; split panes and run commands; spawn and coordinate other agents; read pane output; and wait for output or agent-status changes — all via the `herdr` CLI talking to the running instance over a local unix socket. Use when running inside herdr (HERDR_ENV=1)."
---

# herdr — agent control skill

Before doing anything, confirm you are inside herdr: check that `HERDR_ENV=1` (and `HERDR_PANE_ID` is set). If it is not, say you are not running inside a herdr-managed pane and **stop** — do not touch a herdr session you do not own.

You are running inside herdr, a terminal-native agent multiplexer. herdr gives you **workspaces → tabs → panes**; each pane is a real terminal running its own shell, agent, server, or log stream, and you can control all of it from the `herdr` CLI, which talks to the running instance over a local unix socket.

This lets you:

- see what other panes and agents are doing
- create tabs and split panes for separate subcontexts
- start servers, watch logs, and run tests in sibling panes
- wait for specific output before continuing
- wait for another agent to finish
- spawn more agent instances and coordinate with them

For the raw protocol, read the [socket api docs](https://herdr.dev/docs/socket-api/).

## Concepts

- **workspace** — a project context (usually one repo/folder). Has one or more tabs.
- **tab** — a subcontext inside a workspace. Has one or more panes.
- **pane** — a terminal split inside a tab, running its own process.
- **agent_status** — herdr auto-detects each pane's state: `idle`, `working`, `blocked`, `done`, `unknown`. `done` means the agent finished but you have not looked at that finished pane yet.

## IDs are opaque — parse them, never construct them

IDs are short opaque strings, **not** small integers:

| Kind | Example |
|------|---------|
| workspace | `wB` |
| tab | `wB:tX` |
| pane | `wB:p31` |
| terminal (stable agent handle) | `term_65523df8c0d5d2c` |

JSON responses also carry a human-friendly `number` field (`1`, `2`, `3`…). **That number is not an ID** — commands take the opaque id, never the number.

Rules:

- Always parse the real id from a `… list`, `… get`, `create`, or `split` response. Never type a literal like `--workspace 1` and never build an id by hand.
- IDs can change when panes/tabs/workspaces close. Re-read them after anything closes; do not assume an old `wB:p31` is still the same pane later.
- `terminal_id` (`term_…`) is the **stable** handle for an agent — it survives a pane-id renumber and a process restart. Prefer it for agent-level operations and long waits.

## Output conventions

- `workspace`/`tab`/`pane`/`agent` `list`/`get`/`create`/`split`/`current`, `wait …`, and `notification show` print **JSON** on success.
- `pane read` and `agent read` print **text**, not JSON.
- `pane send-text`, `pane send-keys`, and `pane run` print **nothing** on success.

Parse paths confirmed on this herdr:

- `pane current` → `result.pane` (`pane_id`, `tab_id`, `workspace_id`, `terminal_id`, `agent`, `agent_status`, `cwd`).
- `workspace create` → `result.workspace.workspace_id`, `result.tab.tab_id`, `result.root_pane.pane_id` (+ `.terminal_id`).
- `tab create` → `result.tab` and `result.root_pane`.
- `pane split` → `result.pane.pane_id` (+ `.terminal_id`).

## Discover yourself

```bash
herdr pane current      # your pane: result.pane.{pane_id,tab_id,workspace_id,terminal_id}
herdr pane list         # all panes (add --workspace <id> to scope)
herdr workspace list    # all workspaces
herdr tab list --workspace <workspace_id>
```

The focused pane is yours; the others are your neighbors.

## Read another pane

```bash
herdr pane read <pane_id> --source recent-unwrapped --lines 50
```

- `--source visible` — current viewport.
- `--source recent` — recent scrollback as rendered.
- `--source recent-unwrapped` — recent text with soft wraps joined (best for matching/inspecting).
- `--format ansi` (or `--ansi`) — rendered ANSI snapshot, useful for TUI feedback.

## Split a pane and run a command

`pane split` prints the new pane at `result.pane.pane_id`. Parse it, then run a command in it:

```bash
NEW_PANE=$(herdr pane split <pane_id> --direction right --no-focus \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
herdr pane run "$NEW_PANE" "npm run dev"
```

- `--direction right|down`, `--ratio FLOAT`, `--cwd PATH`, `--env KEY=VALUE`.
- `--no-focus` keeps your own pane focused — use it so you do not hijack the user's view.

## Send text or keys

```bash
herdr pane run <pane_id> "echo hello"     # text + a real Enter in one request (the workhorse)
herdr pane send-text <pane_id> "hello"    # text only, no Enter
herdr pane send-keys <pane_id> Enter      # press keys: Enter, Esc, arrows, etc.
```

The key name is `Esc`, not `Escape`. `Esc` ends the current turn now — never send it mid-commit or mid-deploy.

## Wait for output

Block until text appears in a pane (servers, builds, tests). Exit code is `1` on timeout.

```bash
herdr wait output <pane_id> --match "ready on port 3000" --timeout 30000
herdr wait output <pane_id> --match "server.*ready" --regex --timeout 30000
```

**Gotcha:** the match can fire on the **echo of the command you typed**, not just on the program's output. Match on a string that only the program prints (e.g. `ready on port 3000`), not on words you also typed into the pane. For `--source recent` the matcher uses unwrapped text, so pane width does not break matches; inspect the same transcript with `pane read --source recent-unwrapped`.

## Wait for an agent status

```bash
herdr wait agent-status <pane_id> --status done --timeout 60000
```

Use this for the same `done` / `idle` distinction the UI shows. For agent-level waits keyed on the stable terminal handle, see the agent layer below.

## Workspace / tab / pane lifecycle

```bash
herdr workspace create --cwd /path/to/project --label "api" --no-focus   # → result.workspace/tab/root_pane
herdr workspace focus  <workspace_id>
herdr workspace rename <workspace_id> "api server"
herdr workspace close  <workspace_id>

herdr tab create --workspace <workspace_id> --label "logs"               # → result.tab/root_pane
herdr tab focus  <tab_id>
herdr tab close  <tab_id>

herdr pane close <pane_id>
```

Without `--label`, create keeps the default cwd-/number-based name. `--no-focus` keeps your context.

## Agent layer (spawn and steer other agents)

A higher-level wrapper over panes: it tracks **named** agents and their stable `terminal_id`. Targets accept a terminal id, a unique agent name, a detected agent label, or a (legacy) pane id.

```bash
herdr agent list                                  # result.agents[] (same shape as a pane, incl. terminal_id)
herdr agent get   <target>
herdr agent start reviewer --cwd "$PWD" --split right --no-focus -- claude   # spawn a CLI in a split
herdr agent send  <target> "Review the git diff. Do not edit files."
herdr agent read  <target> --source recent-unwrapped --lines 160
herdr agent wait  <target> --status idle --timeout 300000
herdr agent rename <target> reviewer
```

When to use which layer: use **pane** commands for shells, servers, tests, and precise placement; use **agent** commands when you want a named coding agent you spawn, prompt, wait on, and read back.

**Submit gotcha:** `agent send` writes literal text and may not submit it. Follow it with an explicit Enter on the agent's `pane_id` (from `agent get`):

```bash
herdr agent send reviewer "..."
herdr pane send-keys <reviewer_pane_id> Enter
# some agents (e.g. codex) need Enter twice to submit their composer
```

Wait on `idle` (not `done`) for `agent wait`. Prefer waiting on the **terminal_id** so a pane-id renumber can't complete the wait on a different agent.

## Notifications (best-effort)

```bash
herdr notification show "PM: decision ready" --body "pick 1 or 3" --sound request
```

`--sound none|done|request`, `--position top-left|top-right|bottom-left|bottom-right`. This is **best-effort**: if notifications are disabled in `~/.config/herdr/config.toml`, it returns `{"shown": false, "reason": "disabled"}` and does nothing. Never depend on a toast being seen — it is a nudge, not a channel.

## Recipes

### Run a server and wait until it is ready

```bash
NEW_PANE=$(herdr pane split <pane_id> --direction right --no-focus \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
herdr pane run "$NEW_PANE" "npm run dev"
herdr wait output "$NEW_PANE" --match "ready on port" --timeout 30000
herdr pane read "$NEW_PANE" --source recent-unwrapped --lines 20
```

### Run tests in a separate pane and inspect the result

```bash
TEST_PANE=$(herdr pane split <pane_id> --direction down --no-focus \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
herdr pane run "$TEST_PANE" "cargo test"
herdr wait output "$TEST_PANE" --match "test result" --timeout 60000
herdr pane read "$TEST_PANE" --source recent-unwrapped --lines 30
```

### Spawn an agent and give it a task

```bash
herdr agent start reviewer --cwd "$PWD" --split right --no-focus -- claude
herdr agent wait reviewer --status idle --timeout 60000
herdr agent send reviewer "Review the test coverage in src/api/. Do not edit files. End with APPROVE or CHANGES_REQUESTED."
herdr pane send-keys "$(herdr agent get reviewer | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')" Enter
herdr agent wait reviewer --status idle --timeout 300000
herdr agent read reviewer --source recent-unwrapped --lines 200
```

### Coordinate with a sibling agent

```bash
herdr wait agent-status <pane_id> --status done --timeout 120000
herdr pane read <pane_id> --source recent-unwrapped --lines 100
```

## Notes & gotchas

- Re-read ids from `list`/`create`/`split` responses; they renumber on close. Target agents by `terminal_id` for stability.
- Prefer `--no-focus` on split/create so you do not steal the user's focus.
- Use `pane read` for output that already exists; use `wait output` for output you expect next.
- A wait match can hit the command echo — match on output-only strings.
- Notifications may be disabled in config; treat them as best-effort.
- `done`/`idle` is a wake-up signal, not proof of success — read the pane and verify reality (git status, test output, artifacts) before reporting completion.
