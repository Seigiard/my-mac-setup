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
- No path, headless: output `Review failed: headless mode requires a document path. Re-invoke with: Skill("se-doc-review", "mode:headless <path>")` and stop before scanning or launching peers.

Record whether the wrapper was invoked with `mode:headless`; delivery uses that mode after synthesis.

## Scan and freeze peer input

The external payload is the document itself. Unless `SE_SKIP_SECRET_SCAN` is set to a non-empty value other than `0`, require `gitleaks` and run this fail-closed scan before creating tabs:

```bash
gitleaks dir --no-banner --redact --exit-code 2 "$DOC_PATH"
```

Any nonzero exit or unavailable scanner refuses the peer launch and sends nothing externally. In that path, invoke local `compound-engineering:ce-doc-review` with `mode:headless DOC_PATH`, then deliver its envelope with degraded peer coverage. The override deliberately skips this gate; report that fact.

After a clean or explicitly waived scan, copy the document to an isolated temporary directory while preserving its basename and extension:

```bash
DOC_STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/se-doc-review.XXXXXX")
DOC_COPY="$DOC_STAGE_DIR/$(basename "$DOC_PATH")"
cp "$DOC_PATH" "$DOC_COPY"
```

Peers review `DOC_COPY`; the local pass reviews `DOC_PATH`. This keeps both peer inputs stable while local `safe_auto` edits land on the real document.

## Dispatch fresh peers

Read `~/.claude/shared/herdr-peer-launch.md` in full. It owns tab creation, exact models and permissions, concurrent dispatch, wait and read behavior, and close-before-synthesis cleanup.

Set `REPO_ROOT` to the current checkout. Supply the following dispatch briefs as the reference's `CLAUDE_PROMPT` and `OPENCODE_PROMPT` inputs.

### Claude prompt

```text
[ce-doc-review-external-consult]

Invoke `/compound-engineering:ce-doc-review` with these exact arguments:

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

After the shared lifecycle submits both prompts and before it waits, invoke the local `compound-engineering:ce-doc-review` with `mode:headless DOC_PATH`. The local pass is the only review allowed to mutate the document. Whether the local pass succeeds or fails, resume the shared lifecycle through peer read and tab closure.

Accept an envelope only when Coverage accounts for every attempted persona, its counts reconcile, every surviving finding is routed once with its required fields, and the terminal line is exact. A failed or malformed pass degrades coverage; synthesize any surviving envelopes. If all three passes fail, fail the review without modifying the document further.

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

- **Interactive**: print the synthesis, then route unresolved findings through walk through / apply best judgment / append to Open Questions / report only. Use the platform's blocking question tool. During walk-through, present one decision brief at a time using `~/.claude/shared/decision-brief.md` and wait for the answer before continuing.
- **Headless**: append the synthesis to the local envelope when available, otherwise to the surviving peer envelope set. Return the combined text without questions; the caller decides unresolved findings.

Report every local edit, peer failure, malformed envelope, waived secret scan, and remaining unresolved finding.
