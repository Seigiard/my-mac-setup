# Fresh Herdr peer lifecycle

This is the single source of truth for the peer mechanics shared by `se-code-review`, `se-doc-review`, and `se-simplify`. The calling skill owns scope, peer prompts, report validation, synthesis, and apply policy. Read this file in full before every launch.

## Inputs

Resolve these values before launch:

- `REPO_ROOT`: absolute path to the checkout both peers inspect.
- `CLAUDE_PROMPT`: the calling skill's complete Claude dispatch brief.
- `OPENCODE_PROMPT`: the calling skill's complete OpenCode dispatch brief.

Require `HERDR_ENV=1`, `HERDR_WORKSPACE_ID`, `herdr`, `claude`, `opencode`, `herdr-peer-alias`, and `pre-external-secret-scan`. There is no headless fallback. Every run creates new sessions; never resume, reuse, or retain a peer from this or another phase.

The **cleanup boundary** begins when the report transport directory is created. Track each created tab ID immediately. Any non-recoverable launch, prompt, wait, read, or validation failure closes every tab created by this run and removes its report transport files before control returns to the calling skill.

## Scan exposed content

Before allocating aliases or creating tabs, scan the live checkout and both dispatch prompts:

```bash
printf '%s\n%s\n' "$CLAUDE_PROMPT" "$OPENCODE_PROMPT" \
  | pre-external-secret-scan --stdin "$REPO_ROOT"
```

Exit `0` is the only permission to continue. On any nonzero result, stop this lifecycle before reading another section and report that no tab or report transport was created. The command submits tracked, modified, and untracked filesystem content to gitleaks's trusted default detector rules rather than scanning only a Git range. Detected secrets, a missing scanner, a timeout, an invalid target, or any unexpected scanner status refuse the launch. Scanner findings are redacted before they reach output. `SE_SKIP_SECRET_SCAN=1` is an explicit operator waiver; the caller must report that the external peer input was not scanned. No other value waives the scan.

## Create tabs

A peer's registered name is an allocator-owned `color-animal` alias, never a semantic name. Pane-label reconciliation renames any registered agent whose name falls outside that pool, and a live non-pool name also fails the pane-label cutover. `herdr-peer-alias <seed> [reserved-alias ...]` prints one alias that no live agent holds; the second call reserves the first peer's alias, which is picked but not yet registered:

```bash
PEER_RUN_ID="$(date +%s)-$$"
CLAUDE_NAME="$(herdr-peer-alias "claude|$PEER_RUN_ID|$REPO_ROOT")"
OPENCODE_NAME="$(herdr-peer-alias "opencode|$PEER_RUN_ID|$REPO_ROOT" "$CLAUDE_NAME")"

PEER_REPORT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/se-peer-$PEER_RUN_ID.XXXXXX")
chmod 700 "$PEER_REPORT_DIR"
CLAUDE_REPORT_PATH="$PEER_REPORT_DIR/claude.report"
OPENCODE_REPORT_PATH="$PEER_REPORT_DIR/opencode.report"
```

Allocation runs before the cleanup boundary opens. A failed or empty allocation aborts the launch with no tab created and nothing to clean up.

Create one full-size background tab per peer, rooted at the repository without taking focus. Tab labels belong to pane-label reconciliation, which overwrites any manual label on its next pass, so create both tabs unlabelled:

```bash
CLAUDE_TAB_STATE=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" \
  --cwd "$REPO_ROOT" --no-focus)
CLAUDE_TAB=$(printf '%s' "$CLAUDE_TAB_STATE" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["tab"]["tab_id"])')
CLAUDE_PANE=$(printf '%s' "$CLAUDE_TAB_STATE" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])')

OPENCODE_TAB_STATE=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" \
  --cwd "$REPO_ROOT" --no-focus \
  --env 'OPENCODE_CONFIG_CONTENT={"permission":"allow","agent":{"build":{"permission":"allow","reasoningEffort":"high"}}}')
OPENCODE_TAB=$(printf '%s' "$OPENCODE_TAB_STATE" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["tab"]["tab_id"])')
OPENCODE_PANE=$(printf '%s' "$OPENCODE_TAB_STATE" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])')
```

A freshly created tab's root pane can make its following `agent start` return `agent_pane_busy`. On that exact error, wait two seconds and retry the same start once. A failed retry enters the cleanup boundary. A generic startup timeout enters cleanup immediately without retry.

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

Another client can claim an alias between allocation and start. On the exact error `agent_name_taken`, run `herdr-peer-alias` again for that peer with the other peer's alias reserved, then retry the same start once with the new alias; a second failure enters the cleanup boundary.

After a successful start, `$CLAUDE_PANE` and `$OPENCODE_PANE` are the authoritative targets for every later prompt, wait, and read. Pane-label reconciliation may reallocate a peer's alias at any time, so never address a peer by name after start; a pane ID is stable for the life of its pane.

## Prompt both peers

Append the report transport contract to each calling prompt. This is the only permitted file-write exception in a report-only peer: it does not permit changes to the checkout, reviewed document, or any other file.

```bash
CLAUDE_PROMPT="$CLAUDE_PROMPT

[peer-report-transport]
Before ending this turn, write the exact complete report you are returning, byte-for-byte, to $CLAUDE_REPORT_PATH. Write it atomically through $CLAUDE_REPORT_PATH.tmp and rename the completed file to $CLAUDE_REPORT_PATH. The file is the authoritative report transport. After it is durable, return the same report in the UI as usual. Do not write any other file."

OPENCODE_PROMPT="$OPENCODE_PROMPT

[peer-report-transport]
Before ending this turn, write the exact complete report you are returning, byte-for-byte, to $OPENCODE_REPORT_PATH. Write it atomically through $OPENCODE_REPORT_PATH.tmp and rename the completed file to $OPENCODE_REPORT_PATH. The file is the authoritative report transport. After it is durable, return the same report in the UI as usual. Do not write any other file."
```

Submit both augmented prompts before either wait can block:

```bash
herdr agent prompt "$CLAUDE_PANE" "$CLAUDE_PROMPT"
herdr agent prompt "$OPENCODE_PANE" "$OPENCODE_PROMPT"
```

After both submissions, perform any concurrent local work explicitly defined by the calling skill. Skills with no concurrent work proceed directly to waiting.

## Wait and collect

```bash
herdr agent wait "$CLAUDE_PANE" --timeout 1800000
herdr agent wait "$OPENCODE_PANE" --timeout 1800000
```

The report files are the primary transport. A settled peer that did not create a non-empty regular report file gets one bounded recovery prompt to persist its previous answer. A symlink left at the report path is refused outright and never retried: it is a malformed delivery, not a missing one.

```bash
report_is_delivered() {
  local report_path="$1"
  # -f and -s follow symlinks, so a peer could point the report at any file the
  # caller can read and have its content synthesized as that peer's review.
  # Refuse the path without opening it. This is a coherence guard, not a
  # containment boundary: a same-user peer is not contained by it.
  [ ! -L "$report_path" ] || return 1
  [ -f "$report_path" ] && [ -s "$report_path" ]
}

recover_peer_report() {
  local pane="$1" report_path="$2" recovery_prompt
  [ ! -L "$report_path" ] || return 1
  report_is_delivered "$report_path" && return 0

  recovery_prompt="The report transport file is missing or empty. Write your exact complete previous report, byte-for-byte, atomically through $report_path.tmp and rename it to $report_path. Then reply with only the path."
  printf '%s\n' "$recovery_prompt" \
    | pre-external-secret-scan --stdin "$REPO_ROOT" || return 1
  herdr agent prompt "$pane" "$recovery_prompt" \
    --wait --timeout 120000 || return 1

  report_is_delivered "$report_path"
}

CLAUDE_TRANSPORT_OK=1
if ! recover_peer_report "$CLAUDE_PANE" "$CLAUDE_REPORT_PATH"; then
  CLAUDE_TRANSPORT_OK=0
  CLAUDE_DIAGNOSTIC=$(herdr agent read "$CLAUDE_PANE" --source visible --lines 200 --format text || true)
fi

OPENCODE_TRANSPORT_OK=1
if ! recover_peer_report "$OPENCODE_PANE" "$OPENCODE_REPORT_PATH"; then
  OPENCODE_TRANSPORT_OK=0
  OPENCODE_DIAGNOSTIC=$(herdr agent read "$OPENCODE_PANE" --source recent-unwrapped --lines 200 --format text || true)
fi

[ "$CLAUDE_TRANSPORT_OK" -eq 0 ] || CLAUDE_REPORT=$(<"$CLAUDE_REPORT_PATH")
[ "$OPENCODE_TRANSPORT_OK" -eq 0 ] || OPENCODE_REPORT=$(<"$OPENCODE_REPORT_PATH")
```

A settled state is only a wake-up signal. Pane-backed reads can silently omit alternate-screen history and are diagnostic only; never accept `CLAUDE_DIAGNOSTIC` or `OPENCODE_DIAGNOSTIC` as a report. A failed transport degrades that peer. The calling skill must still validate the complete file-backed report before accepting it.

Two delivered reports are not yet two reviews. Compare them before synthesis, while both files still exist:

```bash
PEER_REPORTS_IDENTICAL=0
if [ "$CLAUDE_TRANSPORT_OK" -eq 1 ] && [ "$OPENCODE_TRANSPORT_OK" -eq 1 ] \
  && cmp -s "$CLAUDE_REPORT_PATH" "$OPENCODE_REPORT_PATH"; then
  PEER_REPORTS_IDENTICAL=1
fi
```

A byte-identical pair is one review delivered twice: one peer performed no independent work, whatever the cause. It degrades exactly like one failed or malformed peer — the run carries single-source coverage, and the surviving report is the single source. It is never consensus, never agreement, and never corroboration of any finding it contains. The calling skill must state the degraded single-source coverage plainly in its synthesis output, name the run as one peer's review rather than two, and grade every finding as unique to that one source. This comparison is exact: a near-identical pair — the same review re-wrapped, reindented, or reserialized — is not detected here and still reads as agreement.

## Close and clean before synthesis

After collecting every available report into memory, close both tabs and remove the transport directory before synthesis:

```bash
CLEANUP_ERRORS=""
herdr tab close "$CLAUDE_TAB" || CLEANUP_ERRORS="$CLEANUP_ERRORS tab:$CLAUDE_TAB"
herdr tab close "$OPENCODE_TAB" || CLEANUP_ERRORS="$CLEANUP_ERRORS tab:$OPENCODE_TAB"
rm -f "$CLAUDE_REPORT_PATH" "$CLAUDE_REPORT_PATH.tmp" \
  "$OPENCODE_REPORT_PATH" "$OPENCODE_REPORT_PATH.tmp" \
  || CLEANUP_ERRORS="$CLEANUP_ERRORS reports:$PEER_REPORT_DIR"
rmdir "$PEER_REPORT_DIR" || CLEANUP_ERRORS="$CLEANUP_ERRORS directory:$PEER_REPORT_DIR"
[ -z "$CLEANUP_ERRORS" ] || printf 'peer cleanup incomplete:%s\n' "$CLEANUP_ERRORS" >&2
```

Tab closure and report-directory removal complete the cleanup boundary. Attempt every recorded tab closure and every cleanup command even when an earlier command fails; report any tab or transport path that remains.
