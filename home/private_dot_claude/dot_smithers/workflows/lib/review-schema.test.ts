import { describe, expect, test } from "bun:test";

import { mergeReviewReports } from "./review-merge.ts";
import { reviewLegJsonSchema, reviewLegSchema } from "./review-schema.ts";

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

describe("natural object → merge call site", () => {
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
