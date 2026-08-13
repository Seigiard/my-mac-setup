import { describe, expect, test } from "bun:test";

import { buildReviewerPrompt, classifyDisposition, failedBlocks, type OutcomeRecord } from "./reviewer.ts";

function record(over: Partial<OutcomeRecord> = {}): OutcomeRecord {
  return {
    runId: "run-1",
    blocks: [
      { blockId: "scan", block: "secret-scan", status: "green" },
      { blockId: "fix", block: "work", status: "green" },
    ],
    ...over,
  };
}

describe("classifyDisposition", () => {
  test("a failed block yields a failure disposition (AE3)", () => {
    const r = record({ blocks: [{ blockId: "review", block: "code-review", status: "failed" }] });
    expect(classifyDisposition(r, undefined)).toBe("failure");
  });

  test("a dead leg (non-terminal) is failure evidence, never a silent clean pass", () => {
    const r = record({ blocks: [{ blockId: "review", block: "code-review", status: "non-terminal" }] });
    expect(classifyDisposition(r, { actionableOptimization: false, summary: "x" })).toBe("failure");
  });

  test("clean success with an actionable optimization yields actionable-optimization", () => {
    expect(classifyDisposition(record(), { actionableOptimization: true, summary: "merge two scans" })).toBe("actionable-optimization");
  });

  test("clean success with no optimization yields clean-success (no issue file)", () => {
    expect(classifyDisposition(record(), { actionableOptimization: false, summary: "nothing" })).toBe("clean-success");
  });
});

describe("failedBlocks", () => {
  test("collects every non-green block", () => {
    const r = record({
      blocks: [
        { blockId: "a", block: "x", status: "green" },
        { blockId: "b", block: "y", status: "degraded" },
        { blockId: "c", block: "z", status: "stopped" },
      ],
    });
    expect(failedBlocks(r).map((b) => b.blockId)).toEqual(["b", "c"]);
  });
});

describe("buildReviewerPrompt", () => {
  test("failure prompt names the failed block and marks log excerpts untrusted", () => {
    const r = record({ blocks: [{ blockId: "review", block: "code-review", status: "failed" }] });
    const prompt = buildReviewerPrompt(r, "leg exited 137");
    expect(prompt).toContain("review (failed)");
    expect(prompt).toContain("untrusted data");
  });

  test("success prompt asks for an optimization verdict", () => {
    expect(buildReviewerPrompt(record(), "ok")).toContain("actionableOptimization=false if none");
  });
});
