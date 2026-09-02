---
title: "OpenCode peer leg of se-code-review returns wrapper-shaped report with fabricated cleanup claims"
short_description: "The OpenCode leg of a se-code-review peer dispatch returned the outer wrapper's own synthesis-report shape instead of a single-model ce-code-review leaf report, and asserted peer_tabs_closed/peer_transport_removed for nested peer sessions it never created."
type: "bug"
category: "agent-platform"
tags: ["se-pipeline","peer-review","herdr"]
date: "2026-09-02"
status: "open"
priority: "medium"
---

## Why this exists

Running se-code-review on test/herdr-task-sync-glyph-contract (base b632c34), the OpenCode/Terra peer (session se-opencode-1788357856-34980) returned a JSON report shaped like se-code-review's own orchestrator output contract -- top-level keys peer_coverage, reviewer_selection: {claude: [...], opencode: [...]}, merged_findings, settled_decision, cleanup.peer_tabs_closed: true, cleanup.peer_transport_removed: true, commit -- instead of the single-model ce-code-review mode:agent leaf report (status/verdict/scope/intent/findings/actionable_findings/...) that the concurrent Claude/Sonnet peer (se-claude-1788357856-34980) produced correctly for the identical prompt and scope. The OpenCode report's cleanup block claimed it had closed peer tabs and removed peer transport files for nested peer sessions of its own. I verified via `herdr agent list` immediately after both legs settled that no such nested se-claude-*/se-opencode-* sessions existed anywhere in the workspace beyond the two legs the orchestrating session itself created (se-claude-1788357856-34980, se-opencode-1788357856-34980) plus unrelated concurrent review sessions from other branches (se-claude-1788356263-85283, se-opencode-1788356263-85283, se-claude-1788357691-501, se-opencode-1788357691-501, se-claude-2942, se-claude-1788356860-61166). The OpenCode leg's content was also thin -- no mention of any specific file, line, or symbol from the reviewed diff (hts_icon, ICON_BRANCH, etc.), unlike the Claude leg's detailed intent/learnings/residual_risks. A leg that fabricates its own cleanup claims can equally fabricate the coverage and findings it reports, which would silently halve review coverage (one leg degrades to noise) while the orchestrator reports two legs settled.

## Scope

Root-cause why the OpenCode/Terra peer produced the outer se-code-review wrapper's report shape (peer_coverage/merged_findings/settled_decision/cleanup/commit) instead of the ce-code-review mode:agent leaf shape, for a prompt that explicitly said 'Use the ce-code-review skill' (see home/private_dot_claude/shared/herdr-peer-launch.md for the shared peer-dispatch mechanics this run used, and the se-code-review skill's own Claude/OpenCode dispatch-brief templates, which are symlinked from an externally-managed skill source per home/private_dot_config/agent-skills/manifest -- EveryInc/compound-engineering-plugin -- and are not authored in this repo). Add a validation step to the shared peer lifecycle or to se-code-review's report acceptance that rejects a peer report whose top-level shape does not match the expected single-model leaf contract, and that treats an unverifiable cleanup/coverage claim (e.g. peer_tabs_closed for tabs the orchestrator never created) as a hard failure of that leg rather than a low-severity finding. Confine any code change to files this repo actually owns (home/private_dot_claude/shared/herdr-peer-launch.md and any repo-owned se-code-review synthesis logic); do not attempt to patch the externally-sourced se-code-review/ce-code-review skill content itself.

## Open decisions

Whether the fix belongs in home/private_dot_claude/shared/herdr-peer-launch.md (shape/cleanup-claim validation added to the shared report-collection step, which this repo owns) or must be reported upstream to EveryInc/compound-engineering-plugin (if the dispatch-brief wording itself is what caused OpenCode to conflate the wrapper and leaf contracts). Confirm whether this is reproducible (a wording ambiguity in the shared review contract boilerplate that both peers receive) or was a one-off model-side confusion specific to this OpenCode/Terra run.
