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

import { ClaudeCodeAgent, OpenCodeAgent } from "smithers-orchestrator";

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
    maxBudgetUsd: 15,
    retries: 1,
  },
  // Opencode finishes in 3-6 min and is cheap — a retry is affordable.
  opencodeReview: {
    model: "openai/gpt-5.5",
    timeoutMs: 15 * 60_000,
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

export interface ClaudeReviewAgentOptions {
  cwd: string;
  profile: "codeReview" | "docReview";
  jsonField: "report" | "envelope";
}

// Consensus leg, not the deep one — the local personas already run on the
// session's top model; Sonnet, never Fable. Default stream-json capture is
// safe: the chunk-join corruption on subagent-heavy runs was fixed by
// 95b4f5736, inside v0.27.0 (spike run a9b4b686, se-pipeline plan KTD9).
export function makeClaudeReviewAgent(options: ClaudeReviewAgentOptions): ClaudeCodeAgent {
  const profile = AGENT_PROFILES[options.profile];
  return new ClaudeCodeAgent({
    cwd: options.cwd,
    permissionMode: "acceptEdits",
    model: profile.model,
    fallbackModel: profile.fallbackModel,
    timeoutMs: profile.timeoutMs,
    maxBudgetUsd: profile.maxBudgetUsd,
    jsonSchema: stringFieldJsonSchema(options.jsonField),
  });
}

export function makeOpencodeReviewAgent(options: { cwd: string }): OpenCodeAgent {
  return new OpenCodeAgent({
    cwd: options.cwd,
    model: AGENT_PROFILES.opencodeReview.model,
    timeoutMs: AGENT_PROFILES.opencodeReview.timeoutMs,
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
