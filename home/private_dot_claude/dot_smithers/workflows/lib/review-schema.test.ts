import { describe, expect, test } from "bun:test";

import { mergeReviewReports } from "./review-merge.ts";
import { isUsableReviewLegStatus, reviewLegJsonSchema, reviewLegSchema } from "./review-schema.ts";

describe("reviewLegSchema", () => {
  test("accepts the plugin's natural object and passes extra fields through", () => {
    const parsed = reviewLegSchema.parse({
      status: "complete",
      verdict: "approve",
      findings: [{ severity: "P1", title: "x" }],
    });
    expect(parsed.status).toBe("complete");
    expect((parsed as Record<string, unknown>).findings).toHaveLength(1);
  });

  test("rejects an object without a string status", () => {
    expect(reviewLegSchema.safeParse({ verdict: "approve" }).success).toBe(false);
    expect(reviewLegSchema.safeParse({ status: 3 }).success).toBe(false);
  });
});

describe("reviewLegJsonSchema", () => {
  test("requires only status and never re-introduces the report wrapper", () => {
    const schema = JSON.parse(reviewLegJsonSchema());
    expect(schema.required).toEqual(["status"]);
    expect(schema.properties.status).toEqual({ type: "string" });
    expect(schema.properties.report).toBeUndefined();
  });
});

describe("isUsableReviewLegStatus", () => {
  test("the observed regression: an unforeseen synonym no longer discards the leg", () => {
    // #given the word an opencode leg reported while carrying a well-formed P3
    // #when / #then it is a leg that ran (docs/issues/2026-08-14-002)
    expect(isUsableReviewLegStatus("findings")).toBe(true);
  });

  test("known success words stay usable", () => {
    for (const status of ["complete", "completed", "SMOKE OK", "reviewers complete", "completed: claude, opencode", "done"]) {
      expect(isUsableReviewLegStatus(status)).toBe(true);
    }
  });

  test("an explicit failure or progress state is still a dead leg", () => {
    for (const status of ["failed", "error", "crashed", "timed out", "pending", "in_progress", "waiting_for_reviewers", "queued", "partial"]) {
      expect(isUsableReviewLegStatus(status)).toBe(false);
    }
  });

  test("a negated success word is a failure, not a success containing one", () => {
    // #given a status that contains "completed" but denies it
    expect(isUsableReviewLegStatus("not completed")).toBe(false);
    expect(isUsableReviewLegStatus("never completed")).toBe(false);
  });

  test("a negated failure word describes health, not the failure", () => {
    // #given statuses that contain "error"/"failures" under a negation
    expect(isUsableReviewLegStatus("no errors")).toBe(true);
    expect(isUsableReviewLegStatus("0 failures")).toBe(true);
    expect(isUsableReviewLegStatus("free of errors")).toBe(true);
  });

  test("a missing, empty or non-string status fails closed", () => {
    // #given an envelope with no usable status field — evidence is absent,
    // which is the case the conservative rule was written for
    expect(isUsableReviewLegStatus(undefined)).toBe(false);
    expect(isUsableReviewLegStatus("")).toBe(false);
    expect(isUsableReviewLegStatus("   ")).toBe(false);
    expect(isUsableReviewLegStatus(3)).toBe(false);
  });
});

describe("natural object → merge call site", () => {
  test("a leg with an unrecognised status contributes its findings to the merge", () => {
    // #given the exact shape of run-1786700241899's opencode leg
    const opencodeOut = { status: "findings", findings: [{ severity: "P3", title: "grapheme clusters split during reversal" }] };

    // #when the legs are merged
    const merged = JSON.parse(
      mergeReviewReports([
        { source: "claude", raw: JSON.stringify({ status: "complete", findings: [] }) },
        { source: "opencode", raw: JSON.stringify(opencodeOut) },
      ]),
    ) as { findings: unknown[]; legs: Record<string, string> };

    // #then the leg counts as healthy and its finding reaches the merged report
    expect(merged.legs).toEqual({ claude: "ok", opencode: "ok" });
    expect(merged.findings).toHaveLength(1);
  });

  test("a leg that says it failed is still discarded, findings and all", () => {
    // #given a leg carrying findings under an explicit failure status
    const merged = JSON.parse(
      mergeReviewReports([
        { source: "claude", raw: JSON.stringify({ status: "complete", findings: [] }) },
        { source: "opencode", raw: JSON.stringify({ status: "failed", findings: [{ severity: "P0", title: "partial" }] }) },
      ]),
    ) as { findings: unknown[]; legs: Record<string, string> };

    // #then fail-closed holds — a dead leg's partial findings are not evidence
    expect(merged.legs).toEqual({ claude: "ok", opencode: "failed" });
    expect(merged.findings).toHaveLength(0);
  });

  test("a captured leg object serializes into ReviewLeg.raw and merges", () => {
    const claudeOut = { status: "complete", verdict: "approve", findings: [{ severity: "P1", title: "kept" }] };
    const merged = JSON.parse(
      mergeReviewReports([
        { source: "claude", raw: JSON.stringify(claudeOut) },
        { source: "opencode", raw: undefined },
      ]),
    ) as { findings: unknown[]; legs: Record<string, string> };
    expect(merged.legs).toEqual({ claude: "ok", opencode: "failed" });
    expect(merged.findings).toHaveLength(1);
  });
});
