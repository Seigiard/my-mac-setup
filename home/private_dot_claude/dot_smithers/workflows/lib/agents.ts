// Single home for external-agent limits, models, and retry policy across the
// se-* workflows (se-code-review, se-doc-review, se-pipeline). Every number
// here is sized from _smithers_attempts history, not guessed — the incident
// trail lives next to the number it produced. Workflows construct agents ONLY
// through these factories; a workflow that needs different caps adds a named
// profile here instead of scattering overrides at call sites.
//
// `retries` is a Task prop, not an agent option — smithers has no per-agent
// retry config. It lives in the profile anyway because retry policy and
// budget are one decision: budget exhaustion is deterministic for a given
// diff, so a retry burns the whole cap again on the same failure (2026-07-23,
// runs 89938dd6/07ffc75d: 4 attempts × ~$15-17 on one diff). JSX reads it as
// retries={AGENT_PROFILES.<profile>.retries}.
//
// `idleTimeoutMs` is the spawn layer's PROCESS_IDLE_TIMEOUT: the timer resets
// on every stdout/stderr byte, so a review CLI that goes silent dies at the
// idle threshold instead of burning the full `timeoutMs` (run 9925bb0d ate the
// 45-min cap on a 10-min stall). Review profiles only — 15 min for the claude
// legs, 10 min for opencode — each strictly under its `timeoutMs`. Values sit
// above the observed pathological floor but are provisional: a healthy leg can
// also fall silent (rate-limit backoff, one long API call, doc-review's
// 12-17-min subagent phases), and codeReview.retries=0 makes a false idle-kill
// irrecoverable. The `work` profile is excluded — long locally-silent commands
// (installs, test suites) are legitimate there.

import { ClaudeCodeAgent, OpenCodeAgent } from "smthrs";
import { reviewLegJsonSchema } from "./review-schema.ts";

// se-simplify apply leg (U1/R5/KTD-F): a single leg applies the cross-model
// consensus after the two report legs agree. It executes already-decided
// findings under a behavior-preservation guard — high-care, not
// deep-reasoning — so Sonnet is the cost/quality point; Opus (the `work`
// profile) stays reserved for implementation-from-scratch. Named here so the
// apply Task reads the model from the single agent home, never a call site.
export const SIMPLIFY_APPLY_MODEL = "claude-sonnet-5" as const;
export const SIMPLIFY_APPLY_FALLBACK_MODEL = "claude-haiku-4-5" as const;

// Observed burn of a sonnet-5 review leg on a big diff (run 89938dd6:
// ~$17 in ~13 min). Budget and timeout must scale together — a budget that
// does not fit in the timeout converts every over-budget run into a timeout.
export const CLAUDE_REVIEW_BURN_USD_PER_MIN = 1.3;

export const AGENT_PROFILES = {
  // Code-review legs (se-code-review externals, se-pipeline verify-code):
  // diff-driven cost. A normal diff bills ~$5-8; 4800+ lines billed ~$17
  // (run 89938dd6) and needed ~36 min wall clock (run 9c38b3ea). A 15-min
  // cap also killed attempt 1 in 4/4 doc-review-shaped runs (platform-3,
  // run 46dec4cf) — hence 45 min.
  codeReview: {
    model: "claude-sonnet-5",
    fallbackModel: "claude-haiku-4-5",
    timeoutMs: 45 * 60_000,
    idleTimeoutMs: 15 * 60_000,
    maxBudgetUsd: 40,
    retries: 0,
  },
  // Doc review is high-judgment but lighter than a code diff: the full
  // plugin workflow (~7 persona subagents) runs ~12-17 min cold and bills
  // ~$5-6. Kept deliberately cheaper than codeReview — do not merge them.
  docReview: {
    model: "claude-sonnet-5",
    fallbackModel: "claude-haiku-4-5",
    timeoutMs: 25 * 60_000,
    idleTimeoutMs: 15 * 60_000,
    maxBudgetUsd: 15,
    retries: 1,
  },
  // Simplify review legs (se-simplify externals, se-pipeline simplify stage):
  // the ce-simplify-code reviewer personas (reuse/quality/efficiency) on the
  // work diff. Judgment-heavy but lighter than a full code-review diff pass,
  // so sized like docReview, not codeReview. Sonnet class matches
  // ce-simplify-code's stated reviewer tier (KTD-F); haiku fallback rides out a
  // Max-subscription throttle. Retries=1 is affordable — a failed leg only
  // degrades to advisory (skip-when-unsure), never mutates.
  simplifyReview: {
    model: "claude-sonnet-5",
    fallbackModel: "claude-haiku-4-5",
    timeoutMs: 25 * 60_000,
    idleTimeoutMs: 15 * 60_000,
    maxBudgetUsd: 15,
    retries: 1,
  },
  // Opencode finishes in 3-6 min and is cheap — a retry is affordable.
  opencodeReview: {
    model: "openai/gpt-5.5",
    timeoutMs: 15 * 60_000,
    idleTimeoutMs: 10 * 60_000,
    retries: 1,
  },
  // Implementation leg (se-pipeline work stage): Opus for implementation,
  // Sonnet fallback rides out a Max-subscription throttle instead of failing
  // the stage. Timeout and budget are operator inputs, not profile constants.
  work: {
    model: "claude-opus-4-8",
    fallbackModel: "claude-sonnet-5",
  },
} as const;

// Native structured-output enforcement (claude CLI --json-schema). Smithers
// does NOT derive this from the Task's Zod schema — without it the final
// message is free-form text and capture fails on subagent-heavy sessions.
export function stringFieldJsonSchema(field: "report" | "envelope"): string {
  return JSON.stringify({
    type: "object",
    properties: { [field]: { type: "string" } },
    required: [field],
  });
}

// codeReview captures the plugin's natural review object directly (single
// source: lib/review-schema.ts) — no {report: string} wrapper. docReview still
// wraps its free-form markdown in {envelope: string} (R7), so the json-schema
// is scoped per profile and only the code-review contract unwraps.
// simplifyReview emits the SAME raw-object json-schema as codeReview (R3): the
// leg returns {status, findings[]} directly so mergeSimplifyLegs' parseLeg
// (which requires a top-level findings array) reads it — a {report: "..."}
// string wrapper would fail that parse and mark every leg failed.
export type ClaudeReviewAgentOptions =
  | { cwd: string; profile: "codeReview" }
  | { cwd: string; profile: "simplifyReview" }
  | { cwd: string; profile: "docReview"; jsonField: "envelope" };

const RAW_OBJECT_PROFILES = new Set(["codeReview", "simplifyReview"]);

// System-level reinforcement of the consult prompt's synchronous-dispatch rule
// (lib/consult-prompt.ts): the claude review legs run personas as subagents, and
// a leg that backgrounded them lost that detached state across a turn,
// re-dispatched a reviewer, and doubled wall time (24 min vs ~8, run cfab0f58).
// The claude CLI has no flag to disable background execution (it is a Task/Bash
// parameter, and Task itself is required for personas), so this pins the rule at
// the system level where adherence beats the user-message rule alone.
const SYNCHRONOUS_SUBAGENTS_SYSTEM_PROMPT =
  "When you run reviewer personas as subagents, dispatch all of them in one message as parallel BLOCKING calls and wait for every one within that same turn. Never background or detach a subagent, never use any run-in-background mode, and never arm a file-watch monitor or poll for completion: detached subagent state is not durable across turns and forces a full, wasteful re-run.";

// Consensus leg, not the deep one — the local personas already run on the
// session's top model; Sonnet, never Fable. Default stream-json capture is
// safe: the chunk-join corruption on subagent-heavy runs was fixed by
// 95b4f5736, inside v0.27.0 (spike run a9b4b686, se-pipeline plan KTD9).
export function makeClaudeReviewAgent(options: ClaudeReviewAgentOptions): ClaudeCodeAgent {
  const profile = AGENT_PROFILES[options.profile];
  return new ClaudeCodeAgent({
    cwd: options.cwd,
    permissionMode: "acceptEdits",
    appendSystemPrompt: SYNCHRONOUS_SUBAGENTS_SYSTEM_PROMPT,
    model: profile.model,
    fallbackModel: profile.fallbackModel,
    timeoutMs: profile.timeoutMs,
    idleTimeoutMs: profile.idleTimeoutMs,
    maxBudgetUsd: profile.maxBudgetUsd,
    jsonSchema: RAW_OBJECT_PROFILES.has(options.profile) ? reviewLegJsonSchema() : stringFieldJsonSchema((options as { jsonField: "envelope" }).jsonField),
  });
}

export interface SimplifyApplyAgentOptions {
  cwd: string;
  timeoutMs: number;
  maxBudgetUsd: number;
}

// The single apply owner (R5/R6): applies the synthesized consensus+unique
// findings on repoPath, re-locating each by surrounding content (line numbers
// are advisory anchors). acceptEdits is enough — the apply leg only EDITS
// files; the pipeline (or standalone verify Task) owns commit + validate-cmd,
// so it never needs bypassPermissions. Sonnet per KTD-F.
export function makeSimplifyApplyAgent(options: SimplifyApplyAgentOptions): ClaudeCodeAgent {
  return new ClaudeCodeAgent({
    cwd: options.cwd,
    permissionMode: "acceptEdits",
    model: SIMPLIFY_APPLY_MODEL,
    fallbackModel: SIMPLIFY_APPLY_FALLBACK_MODEL,
    timeoutMs: options.timeoutMs,
    maxBudgetUsd: options.maxBudgetUsd,
    jsonSchema: stringFieldJsonSchema("report"),
  });
}

export function makeOpencodeReviewAgent(options: { cwd: string }): OpenCodeAgent {
  return new OpenCodeAgent({
    cwd: options.cwd,
    model: AGENT_PROFILES.opencodeReview.model,
    timeoutMs: AGENT_PROFILES.opencodeReview.timeoutMs,
    idleTimeoutMs: AGENT_PROFILES.opencodeReview.idleTimeoutMs,
  });
}

// se-simplify right-sizing classifier (R14/KTD-I): the cheapest tier answers
// "is this diff substantive enough to warrant simplify?" only when the
// deterministic stage-gate is inconclusive. Cheap and fast — a tight budget and
// timeout, no fallback (a classifier failure defaults to SKIP, the safe bias).
export const SIMPLIFY_CLASSIFIER_MODEL = "claude-haiku-4-5" as const;

export function makeSimplifyClassifierAgent(options: { cwd: string }): ClaudeCodeAgent {
  return new ClaudeCodeAgent({
    cwd: options.cwd,
    permissionMode: "default",
    model: SIMPLIFY_CLASSIFIER_MODEL,
    timeoutMs: 3 * 60_000,
    idleTimeoutMs: 2 * 60_000,
    maxBudgetUsd: 1,
    jsonSchema: JSON.stringify({
      type: "object",
      properties: { run: { type: "boolean" }, reason: { type: "string" } },
      required: ["run"],
    }),
  });
}

export interface WorkAgentOptions {
  cwd: string;
  timeoutMs: number;
  maxBudgetUsd: number;
  jsonField: "report" | "envelope";
}

// bypassPermissions: KTD12 — acceptEdits is not enough for headless commits.
export function makeWorkAgent(options: WorkAgentOptions): ClaudeCodeAgent {
  return new ClaudeCodeAgent({
    cwd: options.cwd,
    permissionMode: "bypassPermissions",
    dangerouslySkipPermissions: true,
    model: AGENT_PROFILES.work.model,
    fallbackModel: AGENT_PROFILES.work.fallbackModel,
    timeoutMs: options.timeoutMs,
    maxBudgetUsd: options.maxBudgetUsd,
    jsonSchema: stringFieldJsonSchema(options.jsonField),
  });
}
