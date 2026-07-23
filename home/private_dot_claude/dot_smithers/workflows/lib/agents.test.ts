import { describe, expect, test } from "bun:test";
import {
  AGENT_PROFILES,
  CLAUDE_REVIEW_BURN_USD_PER_MIN,
  makeClaudeReviewAgent,
  makeOpencodeReviewAgent,
  makeWorkAgent,
  stringFieldJsonSchema,
} from "./agents.ts";

describe("AGENT_PROFILES invariants", () => {
  const claudeReviewProfiles = ["codeReview", "docReview"] as const;

  test.each(claudeReviewProfiles)("%s budget fits inside its timeout at observed burn rate", (name) => {
    const profile = AGENT_PROFILES[name];
    const minutesToExhaustBudget = profile.maxBudgetUsd / CLAUDE_REVIEW_BURN_USD_PER_MIN;
    expect(profile.timeoutMs / 60_000).toBeGreaterThanOrEqual(minutesToExhaustBudget);
  });

  test("claude review legs never retry a deterministic budget failure on the expensive profile", () => {
    expect(AGENT_PROFILES.codeReview.retries).toBe(0);
  });

  test("every review profile declares an explicit retry policy", () => {
    expect(AGENT_PROFILES.codeReview.retries).toBeDefined();
    expect(AGENT_PROFILES.docReview.retries).toBeDefined();
    expect(AGENT_PROFILES.opencodeReview.retries).toBeDefined();
  });

  test("claude review profiles keep a fallback model for subscription throttles", () => {
    for (const name of claudeReviewProfiles) {
      expect(AGENT_PROFILES[name].fallbackModel).toBeTruthy();
      expect(AGENT_PROFILES[name].fallbackModel).not.toBe(AGENT_PROFILES[name].model);
    }
  });
});

describe("stringFieldJsonSchema", () => {
  test.each(["report", "envelope"] as const)("emits a valid schema requiring only %s", (field) => {
    const schema = JSON.parse(stringFieldJsonSchema(field));
    expect(schema.required).toEqual([field]);
    expect(schema.properties[field]).toEqual({ type: "string" });
  });
});

describe("factories", () => {
  test("claude review factory builds for both profiles and json fields", () => {
    expect(makeClaudeReviewAgent({ cwd: "/tmp", profile: "codeReview", jsonField: "report" })).toBeDefined();
    expect(makeClaudeReviewAgent({ cwd: "/tmp", profile: "docReview", jsonField: "envelope" })).toBeDefined();
  });

  test("opencode and work factories build", () => {
    expect(makeOpencodeReviewAgent({ cwd: "/tmp" })).toBeDefined();
    expect(makeWorkAgent({ cwd: "/tmp", timeoutMs: 60_000, maxBudgetUsd: 1, jsonField: "report" })).toBeDefined();
  });
});
