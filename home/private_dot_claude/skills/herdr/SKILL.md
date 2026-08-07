---
name: herdr
description: "Control herdr from inside it: manage workspaces, tabs, and panes; split panes and run commands; spawn and coordinate other agents; read pane output; and wait for output or agent-status changes — all via the `herdr` CLI talking to the running instance over a local unix socket. Use when running inside herdr (HERDR_ENV=1)."
---

# herdr — agent control skill

Before doing anything, confirm you are inside herdr:

```bash
test "${HERDR_ENV:-}" = 1
```

If the check fails, say you are not running inside a herdr-managed pane and **stop** — do not touch a herdr session you do not own.

You are running inside herdr, a terminal-native agent multiplexer. herdr gives you **workspaces → tabs → panes**; each pane is a real terminal running its own shell, agent, server, or log stream, and you control all of it from the `herdr` CLI. This lets you:

- see what other panes and agents are doing
- create tabs and split panes for separate subcontexts
- start servers, watch logs, and run tests in sibling panes
- wait for specific output before continuing
- wait for another agent to finish
- spawn more agent instances and coordinate with them

## Learn the current CLI

The installed binary is the authority for command syntax. `herdr <command> --help` does NOT print subcommand help — it falls through to the generic usage. Instead:

- Print a command group by running it bare: `herdr pane`, `herdr agent`, `herdr workspace`, `herdr tab`. There is no `herdr wait` group — waiting lives at `herdr pane wait-output` and `herdr agent wait`.
- For flags, read the completion script: `herdr completion zsh | grep -A 12 '(split)'`.
- Do not run bare `herdr` for discovery; it launches or attaches the TUI.
- Do not probe a mutating command by omitting arguments. Commands such as `herdr workspace create` are valid with defaults and will execute.

## Concepts

- **workspace** — a project context (usually one repo/folder). Has one or more tabs.
- **tab** — a subcontext inside a workspace. Has one or more panes.
- **pane** — a terminal split inside a tab, running its own process.
- **agent_status** — herdr auto-detects each pane's state: `idle`, `working`, `blocked`, `done`, `unknown`. `done` means the agent finished but its tab has not been seen in the focused UI yet; focusing marks it seen, CLI reads do not. `blocked` means herdr recognized an approval or question UI. `unknown` does not prove completion.

## IDs are opaque — parse them, never construct them

IDs are short opaque strings, not small integers: workspace `w4`, tab `w4:t9`, pane `w4:p18`, terminal `term_6583ab6b1c5026`.

- JSON responses also carry a human-friendly `number` field. **That number is not an ID** — commands take the opaque id, never the number.
- Always parse the real id from a `… list`, `… get`, `create`, or `split` response. Never build an id by hand.
- Closed tab and pane IDs are not reused; a moved pane gets a new workspace-qualified ID (continue with `.result.move_result.pane.pane_id`).
- `terminal_id` (`term_…`) is a **stable identity** in pane/agent JSON — use it to recognize the same agent across pane renumbering. Agent commands do NOT accept it as a target: they take a unique live agent name or the hosting pane ID.

## Caller context

herdr injects your own coordinates into each managed pane: `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID`. Prefer `--current` when a pane command should target your calling pane. Omitting a target may use the UI-focused pane, which can belong to the user or another client.

Discover live state:

```bash
herdr pane current --current   # you: result.pane.{pane_id,tab_id,workspace_id,terminal_id,agent,agent_status,cwd}
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr workspace list
herdr tab list --workspace "$HERDR_WORKSPACE_ID"
herdr agent list
```

## Output conventions

- Most control commands print JSON on success. `workspace create` returns `.result.workspace`, `.result.tab`, `.result.root_pane`; `tab create` returns `.result.tab` and `.result.root_pane`; `pane split` returns `.result.pane`.
- `pane read` and `agent read` print text, not JSON.
- `pane send-text`, `pane send-keys`, and `pane run` print nothing on success.
- CLI server errors are JSON on stderr with exit status 1; CLI syntax errors exit with status 2.

## Split a pane and run a command

Default to a sibling pane in the current tab and the current working directory. Do not create a workspace, tab, worktree, or different cwd unless the user explicitly requests it. Split a wide pane to the right and a narrow or tall pane down; avoid repeated same-direction splits that create unusably narrow columns. `--no-focus` keeps the user's focus where it is.

```bash
NEW_PANE=$(herdr pane split --current --direction right --cwd "$PWD" --no-focus \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
herdr pane run "$NEW_PANE" "npm run dev"
```

Flags: `--direction right|down`, `--ratio FLOAT`, `--cwd PATH`, `--env KEY=VALUE`, `--current`, `--no-focus`.

## Send text or keys

```bash
herdr pane run <pane_id> "echo hello"     # text + a real Enter in one request (the workhorse)
herdr pane send-text <pane_id> "hello"    # text only, no Enter
herdr pane send-keys <pane_id> enter      # press keys: enter, esc, arrows, ctrl+c, …
```

Key names are validated before any bytes are written; use lowercase logical names (`esc`, `ctrl+c`). `esc` ends an agent's current turn immediately — never send it mid-commit or mid-deploy.

## Wait for output

`pane wait-output` blocks until text appears in a pane (servers, builds, tests). It searches the selected snapshot immediately, so output that already exists can match at once. Omitting `--timeout` waits indefinitely; on timeout the exit status is non-zero.

```bash
herdr pane wait-output <pane_id> --match "ready on port 3000" --timeout 30000
herdr pane wait-output <pane_id> --regex "server.*ready" --timeout 30000
```

Flags: `--match TEXT` (literal) or `--regex PATTERN` (Rust regex, mutually exclusive), `--source visible|recent|recent-unwrapped`, `--lines N`, `--raw`.

**Gotcha:** the match can fire on the **echo of the command you typed**, not just on the program's output. Match on a string only the program prints (`ready on port 3000`), not on words you also typed into the pane.

## Read a pane

```bash
herdr pane read <pane_id> --source recent-unwrapped --lines 50
```

- `--source visible` — current viewport.
- `--source recent` — recent scrollback as rendered, including soft wraps.
- `--source recent-unwrapped` — soft wraps joined; prefer it for logs and transcripts.
- `--source detection` — the plain-text snapshot used for agent detection.
- `--format ansi` (or `--ansi`) — rendered ANSI snapshot, when colors and styling are evidence.

`--lines` asks for more rows from the pane's screen and host scrollback. If increasing it does not reveal more of a completed response, the pane is probably on the terminal's alternate screen; those rows never enter host scrollback. Fallback (only after such a failed read): ask the agent to write its complete response as Markdown to a temp file and reply with the path, then read the file.

## Agent layer (spawn and steer other agents)

Pane commands control raw terminals; agent commands control the recognized coding agent occupying a pane, with lifecycle validation. Agent targets are a **unique live agent name** or the **hosting pane ID** — not terminal IDs, not bare kind labels. Names match `[a-z][a-z0-9_-]{0,31}`, must be unique among live agents, and clear when the agent exits.

`agent start` requires an existing available shell pane (interactive prompt, no foreground command) and never creates or splits layout — split first, then start:

```bash
NEW_PANE=$(herdr pane split --current --direction right --cwd "$PWD" --no-focus \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
herdr agent start reviewer --kind claude --pane "$NEW_PANE"
herdr agent prompt reviewer "Review the current diff. Report only actionable findings. Do not edit files." --wait --timeout 300000
herdr agent read reviewer --source recent-unwrapped --lines 160
```

- `agent start --kind <kind> --pane <id> [--timeout MS]` returns only after herdr detects the agent ready for input (default 30 s). Run `herdr agent` bare for the installed kind list; pass native agent arguments after `--`.
- `agent prompt` atomically submits text plus Enter, honoring bracketed-paste — no manual Enter needed. `--wait` waits for the first settled `idle`, `done`, or `blocked` state; do not repeat those defaults with `--until`. A prompt from a non-working state must produce a lifecycle change within 5 s, else herdr returns `agent_prompt_stalled`.
- `agent wait <target> --until blocked --timeout 120000` — state-specific waits (`--until` is repeatable; the flag is `--until`, not `--status`). Without `--until` it uses the same settled-state defaults as `prompt --wait`.
- If a wait fails or returns `blocked`, inspect `agent get` and `agent read` before deciding what to send.
- `done`/`idle` is a wake-up signal, not proof of success — read the pane and verify reality (git status, test output, artifacts) before reporting completion.

## Recipes

### Run a server and wait until it is ready

```bash
NEW_PANE=$(herdr pane split --current --direction right --cwd "$PWD" --no-focus \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
herdr pane run "$NEW_PANE" "npm run dev"
herdr pane wait-output "$NEW_PANE" --match "ready on port" --timeout 30000
herdr pane read "$NEW_PANE" --source recent-unwrapped --lines 20
```

### Run tests in a separate pane and inspect the result

```bash
TEST_PANE=$(herdr pane split --current --direction down --cwd "$PWD" --no-focus \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
herdr pane run "$TEST_PANE" "cargo test"
herdr pane wait-output "$TEST_PANE" --match "test result" --timeout 120000
herdr pane read "$TEST_PANE" --source recent-unwrapped --lines 120
```

### Wait for a sibling agent, then read its answer

```bash
herdr agent wait <name-or-pane_id> --until done --until idle --timeout 120000
herdr agent read <name-or-pane_id> --source recent-unwrapped --lines 100
```

## Workspace / tab / pane lifecycle

```bash
herdr workspace create --cwd /path/to/project --label "api" --no-focus
herdr tab create --workspace <workspace_id> --label "logs"
herdr pane close <pane_id>
```

Without `--label`, create keeps the default cwd-/number-based name.

## Notifications (best-effort)

```bash
herdr notification show "PM: decision ready" --body "pick 1 or 3" --sound request
```

`--sound none|done|request`, `--position top-left|top-right|bottom-left|bottom-right`. If notifications are disabled in `~/.config/herdr/config.toml`, this returns `{"shown": false, "reason": "disabled"}` and does nothing. Never depend on a toast being seen — it is a nudge, not a channel.

## Plugin dev gotchas

- `herdr-plugin.toml` edits are picked up ONLY by re-running `herdr plugin link <dir>` (`server reload-config` reads config.toml only; `plugin disable`/`enable` flips a flag only).
- `[[panes]] width/height` in the manifest are ignored by `plugin pane open` — pass `--width`/`--height` explicitly (PopupSize: cells or `"N%"`).
- `defaults/commands.toml` seeds only the first run; the palette reads `~/.config/herdr/command-palette/commands.toml` (mutable user copy, not chezmoi-managed) — sync manually after editing defaults.
- Popups are a per-workspace singleton (`plugin_pane_open_failed: popup already open`). To open a popup from the palette (itself a popup): `type = "shell"`, `pause = false`, `nohup bash -c "sleep 0.4; herdr plugin pane open …" &` — the palette closes, the detached process opens the popup into the freed slot.

## Safety and coordination rules

- Use `--no-focus` for background work; do not steal the user's focus or hijack their view.
- Target with `--current`, an explicit id, or a unique agent name. Never rely on another client's focused pane.
- Do not close workspaces, tabs, panes, or sessions you did not create unless the user explicitly asked.
- Never run `herdr server stop` from an active session unless the user explicitly intends to stop the server and every pane process in it.
- Never kill the main herdr process. Use named test sessions (`herdr --session <name>`) for experiments that need an isolated server.
- Re-read ids after anything closes; they renumber. Use `pane read` for output that already exists; use `pane wait-output` for output you expect next.
