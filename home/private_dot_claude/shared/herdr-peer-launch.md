# External leg pair interface

An External leg pair is one Claude review and one OpenCode review of the same input. `se-external-leg-pair` owns their shared executable lifecycle for `se-code-review`, `se-doc-review`, and `se-simplify`. Calling skills own scope, complete peer prompts, report-schema validation, synthesis, and apply policy.

## Invocation

Write each complete caller-owned prompt to an absolute path naming a private, readable, non-empty regular file that is not a symlink, then run:

```bash
PAIR_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/se-external-leg-pair-result.XXXXXX") || exit 1
PAIR_RESULT="$PAIR_PARENT/result"

PAIR_STATUS=0
se-external-leg-pair \
  --complexity medium \
  --effort high \
  --repo-root "$REPO_ROOT" \
  --claude-prompt-file "$CLAUDE_PROMPT_FILE" \
  --opencode-prompt-file "$OPENCODE_PROMPT_FILE" \
  --result-dir "$PAIR_RESULT" || PAIR_STATUS=$?
```

If either prompt tells a peer to read a document outside `REPO_ROOT`, add exactly one `--exposed-document "$ABSOLUTE_DOCUMENT"` so the file is scanned too. This is required for the immutable copy used by `se-doc-review`; the interface supports only one external document per pair.

The command requires `HERDR_ENV=1`, `HERDR_WORKSPACE_ID`, and explicit `--complexity` and `--effort` values. Complexity selects each provider's model; effort becomes Claude's native effort and OpenCode's model variant. It also fixes the pair, permissions, retry limits, waits, report transport, and cleanup, so callers cannot override provider or lifecycle policy. `SE_SKIP_SECRET_SCAN=1` remains the only operator waiver. The result records `"scan": "waived"`, and the caller reports the waiver.

Mapping `external-leg-models/2026-09-12` was verified against Claude Code 2.1.236 and OpenCode 1.18.30:

| Complexity | Claude model | OpenCode model |
|---|---|---|
| `low` | `sonnet` | `openai/gpt-5.6-luna` |
| `medium` | `sonnet` | `openai/gpt-5.6-terra` |
| `high` | `opus` | `openai/gpt-5.6-sol` |
| `xhigh` | `fable` | `openai/gpt-6-astra` |

Both clients support `low`, `medium`, `high`, `xhigh`, and `max` effort for these models. The three current callers declare `medium/high`, preserving their previous Sonnet/high and Terra behavior.

## Result

The command copies usable reports only after every known peer tab closes, then removes private transport before publishing `PAIR_RESULT`. Cleanup failure exits `3` and publishes nothing. Stderr identifies any resource it could not remove or any successful tab creation that returned no trackable tab ID.

`result.json` contains:

- `interface`: always `se-external-leg-pair/v1`.
- `classification`: `paired`, `claude-only`, `opencode-only`, `identical-single`, or `none`.
- `scan`: `clean` or `waived`.
- `cleanup`: always `complete` in a published result.
- `legs`: lifecycle and transport state for Claude and OpenCode.
- `reports`: source and relative path for every usable report.
- `selection`: mapping version, requested semantic values, and launcher-resolved settings sent to each client.

`selection.resolved` records the launch contract for cost and tuning comparisons. A client or organization policy may still substitute or cap those settings after launch; the executable does not claim to observe that effective runtime identity.

Report files preserve the bytes delivered through peer-owned atomic file transport. When both report files are byte-identical, `identical-single` publishes one `identical.report` attributed to `indeterminate`. Duplicate bytes cannot prove two independent reviews, so this is single-source coverage, never consensus.

Exit statuses:

- `0`: cleanup completed and at least one report is available.
- `1`: cleanup completed but no report is available, or result publication failed.
- `2`: refused before peer creation because input, environment, dependencies, or the initial scan were invalid.
- `3`: cleanup was incomplete; synthesis is forbidden.
- `129`, `130`, or `143`: the process received HUP, INT, or TERM and cleanup completed. Incomplete cleanup overrides these with `3`.

Load and validate every listed report before removing `PAIR_RESULT` and `PAIR_PARENT`. A delivered file is transport evidence only; the calling skill decides whether its content is a valid review report. Pane reads are diagnostic and never appear in the result.

## Ordering guarantees

The executable:

1. Adds each private report path to its complete caller prompt, then scans the checkout, any external document, and both exact augmented prompts immediately before creating tabs.
2. Creates two fresh background tabs and starts the resolved Claude and OpenCode peers.
3. Submits both prompts whose peers reached ready state before waiting on either peer. A trackable failure in one leg does not stop the other; a successful tab creation with no tab ID stops the pair because cleanup cannot be confirmed.
4. Accepts only non-empty regular non-symlink report files.
5. Gives a peer whose initial prompt and wait both succeeded, but whose report is missing or empty, one bounded recovery turn after scanning the recovery prompt and every input it exposes.
6. Classifies byte-identical reports as one source.
7. Attempts all tab and transport cleanup before publishing any result.

Provided cleanup completes, one failed leg does not discard a valid peer report. The calling skill decides whether its own workflow can continue with degraded coverage.
