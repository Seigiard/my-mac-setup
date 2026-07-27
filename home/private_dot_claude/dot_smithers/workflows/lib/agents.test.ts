import { describe, expect, test } from "bun:test";
import {
  AGENT_PROFILES,
  CLAUDE_REVIEW_BURN_USD_PER_MIN,
  SIMPLIFY_APPLY_MODEL,
  makeClaudeReviewAgent,
  makeOpencodeReviewAgent,
  makeSimplifyApplyAgent,
  makeWorkAgent,
  stringFieldJsonSchema,
} from "./agents.ts";

describe("AGENT_PROFILES invariants", () => {
  const claudeReviewProfiles = ["codeReview", "docReview", "simplifyReview"] as const;

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
    expect(AGENT_PROFILES.simplifyReview.retries).toBeDefined();
    expect(AGENT_PROFILES.opencodeReview.retries).toBeDefined();
  });

  test("claude review profiles keep a fallback model for subscription throttles", () => {
    for (const name of claudeReviewProfiles) {
      expect(AGENT_PROFILES[name].fallbackModel).toBeTruthy();
      expect(AGENT_PROFILES[name].fallbackModel).not.toBe(AGENT_PROFILES[name].model);
    }
  });

  const reviewProfilesWithIdle = ["codeReview", "docReview", "simplifyReview", "opencodeReview"] as const;

  test.each(reviewProfilesWithIdle)("%s sets an idle timeout strictly inside its hard timeout", (name) => {
    const profile = AGENT_PROFILES[name];
    expect(profile.idleTimeoutMs).toBeGreaterThan(0);
    expect(profile.idleTimeoutMs).toBeLessThan(profile.timeoutMs);
  });

  test("the work profile carries no idle timeout — long silent commands are legitimate there", () => {
    expect("idleTimeoutMs" in AGENT_PROFILES.work).toBe(false);
  });
});

describe("stringFieldJsonSchema", () => {
  test.each(["report", "envelope"] as const)("emits a valid schema requiring only %s", (field) => {
    const schema = JSON.parse(stringFieldJsonSchema(field));
    expect(schema.required).toEqual([field]);
    expect(schema.properties[field]).toEqual({ type: "string" });
  });
});

describe("simplify apply model", () => {
  test("apply-model constant resolves to a Sonnet-class model, never Opus", () => {
    // #then the apply leg runs on Sonnet (KTD-F: high-care, not deep-reasoning)
    expect(SIMPLIFY_APPLY_MODEL).toContain("sonnet");
    expect(SIMPLIFY_APPLY_MODEL).not.toContain("opus");
  });

  test("simplifyReview reviewers are Sonnet class with a haiku fallback", () => {
    expect(AGENT_PROFILES.simplifyReview.model).toContain("sonnet");
    expect(AGENT_PROFILES.simplifyReview.fallbackModel).toContain("haiku");
  });
});

describe("factories", () => {
  test("claude review factory builds for all three profiles", () => {
    expect(makeClaudeReviewAgent({ cwd: "/tmp", profile: "codeReview" })).toBeDefined();
    expect(makeClaudeReviewAgent({ cwd: "/tmp", profile: "simplifyReview" })).toBeDefined();
    expect(makeClaudeReviewAgent({ cwd: "/tmp", profile: "docReview", jsonField: "envelope" })).toBeDefined();
  });

  test("codeReview + simplifyReview emit the raw-object json-schema; docReview keeps the envelope wrapper", () => {
    const jsonSchemaOf = (agent: ReturnType<typeof makeClaudeReviewAgent>): Record<string, unknown> =>
      JSON.parse((agent as unknown as { opts: { jsonSchema: string } }).opts.jsonSchema);
    const code = jsonSchemaOf(makeClaudeReviewAgent({ cwd: "/tmp", profile: "codeReview" }));
    expect(code.required).toEqual(["status"]);
    expect((code.properties as Record<string, unknown>).report).toBeUndefined();
    // #then simplifyReview matches codeReview — raw object, no {report} wrapper (R3)
    const simplify = jsonSchemaOf(makeClaudeReviewAgent({ cwd: "/tmp", profile: "simplifyReview" }));
    expect(simplify.required).toEqual(["status"]);
    expect((simplify.properties as Record<string, unknown>).report).toBeUndefined();
    const doc = jsonSchemaOf(makeClaudeReviewAgent({ cwd: "/tmp", profile: "docReview", jsonField: "envelope" }));
    expect(doc.required).toEqual(["envelope"]);
  });

  test("simplifyReview claude leg carries the Sonnet model + haiku fallback + its idle timeout", () => {
    const agent = makeClaudeReviewAgent({ cwd: "/tmp", profile: "simplifyReview" });
    expect(agent.idleTimeoutMs).toBe(AGENT_PROFILES.simplifyReview.idleTimeoutMs);
    expect((agent as unknown as { opts: { model: string; fallbackModel: string } }).opts.model).toBe(AGENT_PROFILES.simplifyReview.model);
    expect((agent as unknown as { opts: { model: string; fallbackModel: string } }).opts.fallbackModel).toBe(AGENT_PROFILES.simplifyReview.fallbackModel);
  });

  test("simplify apply factory builds on Sonnet and emits the {report} wrapper, no idle timeout", () => {
    const apply = makeSimplifyApplyAgent({ cwd: "/tmp", timeoutMs: 60_000, maxBudgetUsd: 5 });
    expect((apply as unknown as { opts: { model: string; jsonSchema: string } }).opts.model).toBe(SIMPLIFY_APPLY_MODEL);
    const schema = JSON.parse((apply as unknown as { opts: { jsonSchema: string } }).opts.jsonSchema);
    expect(schema.required).toEqual(["report"]);
    expect(apply.idleTimeoutMs).toBeUndefined();
  });

  test("claude review factory forwards the profile's idle timeout to the constructed agent", () => {
    const code = makeClaudeReviewAgent({ cwd: "/tmp", profile: "codeReview" });
    const doc = makeClaudeReviewAgent({ cwd: "/tmp", profile: "docReview", jsonField: "envelope" });
    expect(code.idleTimeoutMs).toBe(AGENT_PROFILES.codeReview.idleTimeoutMs);
    expect(doc.idleTimeoutMs).toBe(AGENT_PROFILES.docReview.idleTimeoutMs);
  });

  test("opencode factory forwards its idle timeout; work agent carries none", () => {
    const opencode = makeOpencodeReviewAgent({ cwd: "/tmp" });
    expect(opencode.idleTimeoutMs).toBe(AGENT_PROFILES.opencodeReview.idleTimeoutMs);
    const work = makeWorkAgent({ cwd: "/tmp", timeoutMs: 60_000, maxBudgetUsd: 1, jsonField: "report" });
    expect(work.idleTimeoutMs).toBeUndefined();
  });

  test("opencode and work factories build", () => {
    expect(makeOpencodeReviewAgent({ cwd: "/tmp" })).toBeDefined();
    expect(makeWorkAgent({ cwd: "/tmp", timeoutMs: 60_000, maxBudgetUsd: 1, jsonField: "report" })).toBeDefined();
  });
});
