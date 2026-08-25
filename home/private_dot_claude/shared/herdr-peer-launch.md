# Fresh Herdr peer lifecycle

This is the single source of truth for the peer mechanics shared by `se-code-review`, `se-doc-review`, and `se-simplify`. The calling skill owns scope, peer prompts, report validation, synthesis, and apply policy. Read this file in full before every launch.

## Inputs

Resolve these values before launch:

- `REPO_ROOT`: absolute path to the checkout both peers inspect.
- `CLAUDE_PROMPT`: the calling skill's complete Claude dispatch brief.
- `OPENCODE_PROMPT`: the calling skill's complete OpenCode dispatch brief.

Require `HERDR_ENV=1`, `herdr`, `claude`, and `opencode`. There is no headless fallback. Every run creates new sessions; never resume, reuse, or retain a peer from this or another phase.

## Create panes

Use run-scoped agent names no longer than 32 characters:

```bash
PEER_RUN_ID="$(date +%s)-$$"
CLAUDE_NAME="se-claude-$PEER_RUN_ID"
OPENCODE_NAME="se-opencode-$PEER_RUN_ID"
```

Create sibling panes rooted at the repository without taking focus:

```bash
CLAUDE_PANE=$(herdr pane split --current --direction right --cwd "$REPO_ROOT" --no-focus \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')

OPENCODE_PANE=$(herdr pane split "$CLAUDE_PANE" --direction down --cwd "$REPO_ROOT" --no-focus \
  --env 'OPENCODE_CONFIG_CONTENT={"permission":"allow","agent":{"build":{"permission":"allow"}}}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
```

A new pane can briefly return `agent_pane_busy`. Retry only that readiness error; do not retry a generic startup timeout.

## Start exact peers

Start Claude with Sonnet, effort `high`, and permission bypass:

```bash
herdr agent start "$CLAUDE_NAME" \
  --kind claude \
  --pane "$CLAUDE_PANE" \
  --timeout 60000 \
  -- \
  --model sonnet \
  --effort high \
  --dangerously-skip-permissions
```

Start OpenCode with Terra, variant `high`, the build agent, and permission bypass:

```bash
herdr agent start "$OPENCODE_NAME" \
  --kind opencode \
  --pane "$OPENCODE_PANE" \
  --timeout 60000 \
  -- \
  --model openai/gpt-5.6-terra \
  --variant high \
  --agent build \
  --auto
```

Do not substitute another model, effort, variant, agent, permission posture, launcher, or reused session.

## Prompt both peers

Submit both prompts before either wait can block:

```bash
herdr agent prompt "$CLAUDE_NAME" "$CLAUDE_PROMPT"
herdr agent prompt "$OPENCODE_NAME" "$OPENCODE_PROMPT"
```

After both submissions, perform any concurrent local work explicitly defined by the calling skill. Skills with no concurrent work proceed directly to waiting.

## Wait and read

```bash
herdr agent wait "$CLAUDE_NAME" --timeout 1800000
herdr agent wait "$OPENCODE_NAME" --timeout 1800000
```

Read Claude from `visible` and OpenCode from `recent-unwrapped`:

```bash
CLAUDE_REPORT=$(herdr agent read "$CLAUDE_NAME" --source visible --format text)
OPENCODE_REPORT=$(herdr agent read "$OPENCODE_NAME" --source recent-unwrapped --format text)
```

A settled state is only a wake-up signal. The calling skill must validate a complete report before accepting either result.

## Close before synthesis

After reading every available report, close both panes before synthesis:

```bash
herdr pane close "$CLAUDE_PANE"
herdr pane close "$OPENCODE_PANE"
```

Close every pane created by the run on success, launch failure, prompt failure, malformed output, or timeout. If a command fails after the first split, close the panes already created before returning.
