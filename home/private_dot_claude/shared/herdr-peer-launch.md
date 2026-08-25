# Fresh Herdr peer lifecycle

This is the single source of truth for the peer mechanics shared by `se-code-review`, `se-doc-review`, and `se-simplify`. The calling skill owns scope, peer prompts, report validation, synthesis, and apply policy. Read this file in full before every launch.

## Inputs

Resolve these values before launch:

- `REPO_ROOT`: absolute path to the checkout both peers inspect.
- `CLAUDE_PROMPT`: the calling skill's complete Claude dispatch brief.
- `OPENCODE_PROMPT`: the calling skill's complete OpenCode dispatch brief.

Require `HERDR_ENV=1`, `herdr`, `claude`, and `opencode`. There is no headless fallback. Every run creates new sessions; never resume, reuse, or retain a peer from this or another phase.

The **cleanup boundary** begins when the first pane is created. Track each created pane ID immediately. Any non-recoverable launch, prompt, wait, read, or validation failure closes every pane created by this run before control returns to the calling skill.

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
  --env 'OPENCODE_CONFIG_CONTENT={"permission":"allow","agent":{"build":{"permission":"allow","reasoningEffort":"high"}}}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
```

A freshly split pane can make its following `agent start` return `agent_pane_busy`. On that exact error, wait two seconds and retry the same start once. A failed retry enters the cleanup boundary. A generic startup timeout enters cleanup immediately without retry.

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

Start OpenCode with Terra, high reasoning effort from the build-agent config, and permission bypass:

```bash
herdr agent start "$OPENCODE_NAME" \
  --kind opencode \
  --pane "$OPENCODE_PANE" \
  --timeout 60000 \
  -- \
  --model openai/gpt-5.6-terra \
  --agent build \
  --auto
```

The interactive OpenCode entrypoint does not accept the run command's variant flag; keep high reasoning in `agent.build.reasoningEffort`. Do not substitute another model, effort, agent, permission posture, launcher, or reused session.

Each start is complete only when the command succeeds and reports `interactive_ready:true`. Enter the cleanup boundary before prompting if either peer fails this criterion.

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

Pane closure completes the cleanup boundary. Attempt every recorded pane closure even when an earlier close command fails; report any pane that remains open.
