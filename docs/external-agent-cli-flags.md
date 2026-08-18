# External coding-agent CLI flags (headless invocation)

Reference for invoking external coding-agent command-line interfaces in **headless / one-shot** mode. The `ask-in-herdr` skill does not use these recipes: it starts live agents through `herdr-child`. `docs/issues/2026-08-18-003-headless-peer-consult-outside-herdr.md` tracks any future headless peer consult.

**Provenance.** The `claude` row is **verified live** here (Claude Code 2.1.181:
`claude -p` returns clean output, generates its own child session, does not
contaminate the parent transcript). All other rows are transcribed from
**oh-my-claude source** and are **not independently verified** in this repo —
treat them as a starting point, re-check each CLI's `--help` before wiring it in.

Source files (oh-my-claude-sisyphus npm package):
`scripts/run-provider-advisor.js` and `dist/team/model-contract.js`.

## Why this is not a drop-in for ask-in-herdr

Every recipe below runs the provider in **full-permission / yolo** mode (`--dangerously-…`, `--yolo`, `--always-approve`). `ask-in-herdr` instead delegates each live child's tool posture, coordinates, and callback channel to `herdr-child`. A future headless consult must design its own containment and answer transport rather than copying these commands into the live-agent skill.

Codex has sandbox modes and can provide a read-only sandbox after its exact flag is verified. Gemini, Grok, Cursor, and Antigravity have no clean per-call read-only mode in this document; their headless recipes are yolo.

## Flags

| Provider | Binary | Headless invocation | Output |
|---|---|---|---|
| claude | `claude` | `claude -p <prompt>` (or `claude -p` reading the prompt from stdin) | plain text |
| codex | `codex` | `codex exec --dangerously-bypass-approvals-and-sandbox <prompt>` | **JSONL** — parse the last `{type:"message",role:"assistant"}` line |
| gemini | `gemini` | `gemini -p <prompt> --yolo` (a.k.a. `--approval-mode yolo`) | plain text |
| grok | `grok` | `grok -p <prompt> --always-approve` | plain text |
| cursor | `cursor-agent` | `cursor-agent --print --force --trust --sandbox disabled <prompt>` | plain text |
| antigravity | `agy` | `agy --dangerously-skip-permissions -p <prompt>` | plain text |

## Per-provider gotchas

- **Prompt via stdin vs argv (the #3221 trap).** The claude CLI parses a prompt
  whose first token starts with `-` (a leading dash or YAML frontmatter `---`) as
  an **option** and drops the prompt; long / multiline argv is fragile too. Route
  those over stdin (`claude -p` with no prompt arg reads stdin). A future headless
  implementation must pipe when the prompt is leading-dash, multiline, or longer
  than 500 characters; otherwise it can keep `-p <prompt>` in argv.
  - oh-my-claude pipes **codex** and **gemini** via stdin on the same condition
    (multiline / > 500 chars / Windows).
  - **grok** never pipes the prompt — its stdin is reserved for ACP JSON-RPC.
  - **cursor** never pipes — keep stdin closed so prompt bytes aren't read as
    interactive input.
  - **antigravity (`agy`)** never pipes — `-p` takes the prompt as its **value**
    (next token); `agy -p` with no value errors "flag needs an argument".

- **codex output is JSONL.** Read the last assistant `message` line; fall back to a
  `result` / `output` field, else the raw text.

- **antigravity (`agy`) is fragile headless.** Known upstream non-TTY bug
  (`google-antigravity/antigravity-cli#76`): it can exit 0 with **no output**, or
  **hang indefinitely**, and its own `--print-timeout` is non-functional. Bound the
  subprocess yourself and kill with **SIGKILL** (a catchable SIGTERM can be trapped
  and hang past the timeout). Treat empty-output-exit-0 as a failure. **Unsupported
  on Windows** (the `-p` argv path is unreliable there) — fall back to `gemini`.

- **Spawning a non-claude provider from inside Claude Code.** Strip Claude session
  markers so the child doesn't detect/inherit the active session:
  `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, plus the session-id vars
  (`CLAUDE_CODE_SESSION_ID` here; oh-my-claude's list also names
  `CLAUDE_SESSION_ID` / `CLAUDECODE_SESSION_ID`). For **codex** also strip
  `RUST_LOG` / `RUST_BACKTRACE` / `RUST_LIB_BACKTRACE`.
  - For spawning a **child claude**, stripping is **not** needed (verified 2026-06-28
    on 2.1.181): Claude Code already isolates child sessions via
    `CLAUDE_CODE_CHILD_SESSION`.

- **Security gate.** oh-my-claude blocks every non-claude provider when an
  external-LLM-disable policy is set. A yolo mode here should have an equivalent
  opt-in/opt-out.
