---
name: se-doc-review
description: "Review a plan, spec, or requirements document through one local and two fresh cross-model reviews, then synthesize all available envelopes. Use to improve an existing planning document; se-plan invokes it headless."
argument-hint: "[mode:headless] [path/to/document.md]"
---

# Cross-model document review in herdr

Run three independent `ce-doc-review` passes from one pre-review document state:

- The local pass runs headless on the real document and may apply `safe_auto` fixes.
- Two fresh peers run headless on an immutable copy and return report-only envelopes.
- The parent synthesizes all available envelopes after both peer tabs close.

## Resolve the document

Treat tokens beginning with `mode:` as flags. The remaining token, when present, is the document path.

- Path provided: resolve it to an absolute path and require a readable file.
- No path, interactive: ask which document to review, or find the most recent document in `docs/brainstorms/` or `docs/plans/` with a file-search tool.
- No path, headless: output `Review failed: headless mode requires a document path. Re-invoke the se-doc-review skill with: mode:headless <path>` and stop before scanning or launching peers.

Record whether the wrapper was invoked with `mode:headless`; delivery uses that mode after synthesis.

## Freeze peer input

Copy the document to an isolated temporary directory while preserving its basename and extension:

```bash
DOC_STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/se-doc-review.XXXXXX") || exit 1
DOC_INPUT_DIR="$DOC_STAGE_DIR/input"
mkdir "$DOC_INPUT_DIR" || { rm -rf "$DOC_STAGE_DIR"; exit 1; }
DOC_COPY="$DOC_INPUT_DIR/$(basename "$DOC_PATH")"
cp "$DOC_PATH" "$DOC_COPY" || { rm -rf "$DOC_STAGE_DIR"; exit 1; }
```

Peers review `DOC_COPY`; the local pass reviews `DOC_PATH`. The copy remains untouched while the peers run. The shared peer lifecycle owns the one pre-launch full-checkout scan and its fail-closed fallback.

## Dispatch fresh peers

Read `~/.claude/shared/herdr-peer-launch.md` in full. It defines the `se-external-leg-pair` interface and result contract. Set `REPO_ROOT` to the current checkout and compose the following complete dispatch briefs as `CLAUDE_PROMPT` and `OPENCODE_PROMPT`.

### Claude prompt

```text
[ce-doc-review-external-consult]

Invoke `ce-doc-review` with these exact arguments:

mode:headless <absolute DOC_COPY path>

Run the complete document classification, persona selection and dispatch,
validation, synthesis, and headless-envelope flow.

This is an independent report-only review. Do not create, edit, or delete any
repository file or the reviewed document; stage changes; commit; push; switch
branches; or ask interactive questions. The shared lifecycle's report transport
file is the only permitted write. Where the workflow would apply a safe_auto fix,
keep it in the envelope as an applied-candidate finding with the exact suggested edit.

Return the canonical complete headless envelope, not a completion note.
Coverage must name every persona attempted and its status.
Coverage finding counts must reconcile. Route every surviving finding once through
Applied fixes, Proposed fixes, Decisions, FYI observations, Residual concerns,
or Deferred questions, with the evidence and suggested fix required by the
canonical schema. An empty review still includes Coverage with explicit zero
counts. End with the exact line: Review complete
```

### OpenCode prompt

```text
[ce-doc-review-external-consult]

Use the `ce-doc-review` skill with these exact arguments:

mode:headless <absolute DOC_COPY path>

Run the complete document classification, persona selection and dispatch,
validation, synthesis, and headless-envelope flow.

This is an independent report-only review. Do not create, edit, or delete any
repository file or the reviewed document; stage changes; commit; push; switch
branches; or ask interactive questions. The shared lifecycle's report transport
file is the only permitted write. Where the workflow would apply a safe_auto fix,
keep it in the envelope as an applied-candidate finding with the exact suggested edit.

Return the canonical complete headless envelope, not a completion note.
Coverage must name every persona attempted and its status.
Coverage finding counts must reconcile. Route every surviving finding once through
Applied fixes, Proposed fixes, Decisions, FYI observations, Residual concerns,
or Deferred questions, with the evidence and suggested fix required by the
canonical schema. An empty review still includes Coverage with explicit zero
counts. End with the exact line: Review complete
```

Write the complete prompts to private files and invoke the lifecycle once:

```bash
CLAUDE_PROMPT_FILE="$DOC_STAGE_DIR/claude.prompt"
OPENCODE_PROMPT_FILE="$DOC_STAGE_DIR/opencode.prompt"
PAIR_RESULT="$DOC_STAGE_DIR/pair-result"
if ! printf '%s' "$CLAUDE_PROMPT" > "$CLAUDE_PROMPT_FILE" ||
  ! printf '%s' "$OPENCODE_PROMPT" > "$OPENCODE_PROMPT_FILE"; then
  rm -rf "$DOC_STAGE_DIR"
  exit 1
fi
PAIR_STATUS=0
se-external-leg-pair --complexity medium --effort high --repo-root "$REPO_ROOT" \
  --claude-prompt-file "$CLAUDE_PROMPT_FILE" \
  --opencode-prompt-file "$OPENCODE_PROMPT_FILE" \
  --exposed-document "$DOC_COPY" --result-dir "$PAIR_RESULT" || PAIR_STATUS=$?
```

After the command returns, load any published reports needed for synthesis and remove the result and prompt files on every status. Exit `3` then fails the review because peer cleanup is unconfirmed. Otherwise, invoke the local `ce-doc-review` skill with `mode:headless DOC_PATH`; it is the only pass allowed to mutate the document and starts only after peers can no longer read the checkout state attested by the launch scan. Exit `1` or `2` records both peers as failed but does not suppress the local pass.

Accept an envelope only when Coverage accounts for every attempted persona, its counts reconcile, every surviving finding is routed once with its required fields, and the terminal line is exact. A failed or malformed pass degrades coverage; synthesize any surviving envelopes. Treat `identical-single` as one indeterminate source, never consensus. If all three passes fail, fail the review without modifying the document further.

Remove the temporary document copy and its empty staging directory after tab closure or any earlier failure.

## Synthesize envelopes

Merge available envelopes by section and issue substance:

1. **Consensus**: the same finding appears in at least two envelopes. Report it once with every source.
2. **Source-unique**: one pass found it. Preserve attribution and judge it on its merits.
3. **Contradiction**: passes disagree on whether the issue exists or what behavior is correct.
4. **Fix divergence**: passes agree on the issue but propose materially different edits.

If the local pass already applied a finding, mark matching peer findings as confirmation rather than reopening them. Never apply contradictions automatically. Treat cross-model agreement as stronger evidence, not proof.

Present:

```text
## Cross-review synthesis
Coverage: local personas: <list or failed>; Claude peer: <ok or failed>; OpenCode peer: <ok or failed>
### Consensus (N)
### Source-unique findings (M)
### Contradictions / fix divergence (K)
```

## Deliver by mode

- **Interactive**: print the synthesis, then route unresolved findings through walk through / apply best judgment / append to Open Questions / report only. Use the platform's blocking question tool. During walk-through, present one decision at a time and wait for the answer before continuing: name the subject in plain words, state what the decision blocks, give two or three options with the consequence of each, and recommend one. Quote a failure verbatim rather than paraphrasing it.
- **Headless**: append the synthesis to the local envelope when available, otherwise to the surviving peer envelope set. Return the combined text without questions; the caller decides unresolved findings.

Report every local edit, peer failure, malformed envelope, waived secret scan, and remaining unresolved finding.
