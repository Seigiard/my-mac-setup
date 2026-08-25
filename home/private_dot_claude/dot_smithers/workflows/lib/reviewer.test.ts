import { describe, expect, test } from "bun:test";

import { blockLogExcerpts, buildIssueFields, classifyDisposition, failedBlocks, parseReviewerVerdict, type OutcomeRecord } from "./reviewer.ts";

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

describe("parseReviewerVerdict", () => {
  test("reads a well-formed verdict", () => {
    // #given the reviewer returned the full four-field verdict
    const raw = JSON.stringify({ actionableOptimization: true, summary: "merge the scans", cause: "two scans overlap", proposedFix: "drop the second" });

    // #when the epilog parses it
    const verdict = parseReviewerVerdict(raw);

    // #then every field survives
    expect(verdict).toEqual({ actionableOptimization: true, summary: "merge the scans", cause: "two scans overlap", proposedFix: "drop the second" });
  });

  test("a dead reviewer leg is no-verdict, never a silent clean pass (R7)", () => {
    // #given the leg produced nothing
    const verdict = parseReviewerVerdict(undefined);

    // #then the summary says the analysis is missing rather than reporting no findings
    expect(verdict.actionableOptimization).toBe(false);
    expect(verdict.summary).toContain("no usable verdict");
  });

  test("unparseable text is no-verdict", () => {
    expect(parseReviewerVerdict("I could not complete the review").summary).toContain("no usable verdict");
  });

  test("valid JSON without a summary field is no-verdict", () => {
    expect(parseReviewerVerdict(JSON.stringify({ actionableOptimization: true })).summary).toContain("no usable verdict");
  });

  test("a missing optimization flag is false, not truthy-by-absence", () => {
    expect(parseReviewerVerdict(JSON.stringify({ summary: "fine" })).actionableOptimization).toBe(false);
  });
});

describe("blockLogExcerpts", () => {
  test("caps a runaway payload rather than blowing up the prompt", () => {
    const r = record({ blocks: [{ blockId: "a", block: "x", status: "failed" }] });
    const excerpts = blockLogExcerpts(r, () => "z".repeat(5000));
    expect(excerpts).toContain("[truncated]");
    expect(excerpts.length).toBeLessThan(2500);
  });

});

describe("buildIssueFields", () => {
  const base = { date: "2026-08-14", logExcerpts: "excerpt", evidenceArtifacts: ["/tmp/outcome.json"] };

  test("a failure titles the issue after the failed block, not the run id", () => {
    // #given a run whose code-review block failed
    const r = record({ blocks: [{ blockId: "review", block: "code-review", status: "failed" }] });
    const verdict = { actionableOptimization: false, summary: "leg died", cause: "exit 137", proposedFix: "raise the timeout" };

    // #when the issue fields are built
    const fields = buildIssueFields({ record: r, verdict, disposition: "failure", ...base });

    // #then the title and failedBlock name the block
    expect(fields.title).toBe("Flow run failed at block review (code-review)");
    expect(fields.failedBlock).toBe("review (code-review)");
    expect(fields.cause).toBe("exit 137");
  });

  test("an optimization titles the issue after the summary", () => {
    const verdict = { actionableOptimization: true, summary: "merge the scans" };
    const fields = buildIssueFields({ record: record(), verdict, disposition: "actionable-optimization", ...base });
    expect(fields.title).toContain("merge the scans");
    expect(fields.failedBlock).toBeUndefined();
  });

  test("a verdict with no cause falls back to the summary rather than emitting an empty section", () => {
    const r = record({ blocks: [{ blockId: "a", block: "x", status: "failed" }] });
    const fields = buildIssueFields({ record: r, verdict: { actionableOptimization: false, summary: "leg died" }, disposition: "failure", ...base });
    expect(fields.cause).toBe("leg died");
    expect(fields.proposedFix).toContain("triage manually");
  });
});
