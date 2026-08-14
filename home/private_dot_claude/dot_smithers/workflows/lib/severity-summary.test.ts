import { describe, expect, test } from "bun:test";

import { z } from "zod/v4";

import { parseSeveritySummary, severitySchema, stripSeverityLine } from "./severity-summary.ts";
import { reviewSchema } from "../se-doc-review.tsx";

const body = "A".repeat(600);

function envelope(lines: string[]): string {
  return `# Review\n\n${body}\n\n${lines.join("\n")}`;
}

describe("parseSeveritySummary", () => {
  test("valid SEVERITY line in the protected slot → parsed values", () => {
    const e = envelope([`SEVERITY: {"maxSeverity":"P0","p0Count":2,"p1Count":3}`, "Review complete"]);
    expect(parseSeveritySummary(e)).toEqual({ maxSeverity: "P0", p0Count: 2, p1Count: 3 });
  });

  test("maxSeverity is uppercased (loose string)", () => {
    const e = envelope([`SEVERITY: {"maxSeverity":"none","p0Count":0,"p1Count":0}`, "Review complete"]);
    expect(parseSeveritySummary(e)?.maxSeverity).toBe("NONE");
  });

  test("trailing blank lines after Review complete tolerated", () => {
    const e = `${envelope([`SEVERITY: {"maxSeverity":"P1","p0Count":0,"p1Count":1}`, "Review complete"])}\n\n`;
    expect(parseSeveritySummary(e)).toEqual({ maxSeverity: "P1", p0Count: 0, p1Count: 1 });
  });

  test("no SEVERITY line → undefined", () => {
    expect(parseSeveritySummary(envelope(["Review complete"]))).toBeUndefined();
  });

  test("SMOKE OK envelope → undefined", () => {
    expect(parseSeveritySummary("SMOKE OK: first line of the doc")).toBeUndefined();
  });

  test("malformed JSON after the prefix → undefined", () => {
    expect(parseSeveritySummary(envelope([`SEVERITY: {maxSeverity:P0`, "Review complete"]))).toBeUndefined();
  });

  test("non-numeric counts → undefined", () => {
    expect(parseSeveritySummary(envelope([`SEVERITY: {"maxSeverity":"P0","p0Count":"2","p1Count":0}`, "Review complete"]))).toBeUndefined();
  });

  test("negative counts → undefined", () => {
    expect(parseSeveritySummary(envelope([`SEVERITY: {"maxSeverity":"P0","p0Count":-1,"p1Count":0}`, "Review complete"]))).toBeUndefined();
  });

  test("non-integer counts → undefined", () => {
    expect(parseSeveritySummary(envelope([`SEVERITY: {"maxSeverity":"P0","p0Count":1.5,"p1Count":0}`, "Review complete"]))).toBeUndefined();
  });

  test("self-contradictory maxSeverity=P0 with p0Count=0 → undefined", () => {
    expect(parseSeveritySummary(envelope([`SEVERITY: {"maxSeverity":"P0","p0Count":0,"p1Count":0}`, "Review complete"]))).toBeUndefined();
  });

  test("maxSeverity=P1 with zero p1Count → undefined", () => {
    expect(parseSeveritySummary(envelope([`SEVERITY: {"maxSeverity":"P1","p0Count":0,"p1Count":0}`, "Review complete"]))).toBeUndefined();
  });

  test("maxSeverity=NONE with nonzero p0Count → undefined", () => {
    expect(parseSeveritySummary(envelope([`SEVERITY: {"maxSeverity":"none","p0Count":1,"p1Count":0}`, "Review complete"]))).toBeUndefined();
  });

  test("maxSeverity=P1 while p0Count>0 → undefined", () => {
    expect(parseSeveritySummary(envelope([`SEVERITY: {"maxSeverity":"P1","p0Count":2,"p1Count":1}`, "Review complete"]))).toBeUndefined();
  });

  test("unknown maxSeverity token → undefined", () => {
    expect(parseSeveritySummary(envelope([`SEVERITY: {"maxSeverity":"CRITICAL","p0Count":0,"p1Count":0}`, "Review complete"]))).toBeUndefined();
  });

  test("consistent P2 with zero counts → parsed", () => {
    const e = envelope([`SEVERITY: {"maxSeverity":"P2","p0Count":0,"p1Count":0}`, "Review complete"]);
    expect(parseSeveritySummary(e)).toEqual({ maxSeverity: "P2", p0Count: 0, p1Count: 0 });
  });

  test("realistic envelope: decoy SEVERITY in a code fence, real line in slot → real parsed, decoy inert", () => {
    const e = envelope([
      "## Applied fixes",
      "Suggested edit:",
      "```",
      `SEVERITY: {"maxSeverity":"P0","p0Count":9,"p1Count":9}`,
      "```",
      "> quoted prose mentioning SEVERITY: as an example",
      "",
      `SEVERITY: {"maxSeverity":"P1","p0Count":0,"p1Count":4}`,
      "Review complete",
    ]);
    expect(parseSeveritySummary(e)).toEqual({ maxSeverity: "P1", p0Count: 0, p1Count: 4 });
  });

  test("decoy SEVERITY lines in body but protected slot is non-SEVERITY → undefined", () => {
    const e = envelope([
      `SEVERITY: {"maxSeverity":"P0","p0Count":5,"p1Count":0}`,
      "Coverage: personas X, Y",
      "Review complete",
    ]);
    expect(parseSeveritySummary(e)).toBeUndefined();
  });

  test("misordered trailing pair: SEVERITY after Review complete → undefined", () => {
    const e = envelope(["Review complete", `SEVERITY: {"maxSeverity":"P0","p0Count":1,"p1Count":0}`]);
    expect(parseSeveritySummary(e)).toBeUndefined();
  });
});

describe("reviewSchema.refine (R2 regression guard)", () => {
  test("envelope with SEVERITY line in slot still ends with Review complete → valid", () => {
    const e = envelope([`SEVERITY: {"maxSeverity":"P0","p0Count":1,"p1Count":0}`, "Review complete"]);
    expect(reviewSchema.safeParse({ envelope: e }).success).toBe(true);
  });

  test("SMOKE OK bypass still valid", () => {
    expect(reviewSchema.safeParse({ envelope: "SMOKE OK: hello" }).success).toBe(true);
  });

  test("envelope not ending in Review complete → invalid", () => {
    expect(reviewSchema.safeParse({ envelope: `${body}\nno terminal` }).success).toBe(false);
  });
});

// U2: the shared severitySchema is the single source of truth for the fields
// added to both se-doc-review outputSchema and se-pipeline docReviewSchema
// (structural parity — one import, no hand-kept mirror to drift). These guard
// the roundtrip and back-compat claims that the stage schemas inherit.
describe("severitySchema (U2 stage-field parity)", () => {
  const stageOutput = severitySchema.optional();

  test("severity survives JSON stringify/parse roundtrip", () => {
    const value = { maxSeverity: "P0", p0Count: 1, p1Count: 2 };
    const roundtripped = JSON.parse(JSON.stringify(value));
    expect(severitySchema.parse(roundtripped)).toEqual(value);
  });

  test("old shape (severity field absent) still validates — back-compat", () => {
    expect(stageOutput.parse(undefined)).toBeUndefined();
  });

  test("negative or non-integer counts rejected at the schema boundary", () => {
    expect(severitySchema.safeParse({ maxSeverity: "P0", p0Count: -1, p1Count: 0 }).success).toBe(false);
    expect(severitySchema.safeParse({ maxSeverity: "P0", p0Count: 1.5, p1Count: 0 }).success).toBe(false);
  });

  test("a parsed real envelope populates a stage severity field", () => {
    const e = envelope([`SEVERITY: {"maxSeverity":"P0","p0Count":1,"p1Count":0}`, "Review complete"]);
    const claudeSeverity = parseSeveritySummary(e);
    expect(z.object({ claudeSeverity: stageOutput }).parse({ claudeSeverity })).toEqual({
      claudeSeverity: { maxSeverity: "P0", p0Count: 1, p1Count: 0 },
    });
  });
});

describe("stripSeverityLine", () => {
  test("removes the SEVERITY machine line, keeps the rest", () => {
    const e = envelope([`SEVERITY: {"maxSeverity":"P0","p0Count":1,"p1Count":0}`, "Review complete"]);
    const stripped = stripSeverityLine(e);
    expect(stripped).not.toContain("SEVERITY:");
    expect(stripped.trimEnd().endsWith("Review complete")).toBe(true);
  });

  test("no-op when there is no SEVERITY line", () => {
    const e = envelope(["Review complete"]);
    expect(stripSeverityLine(e)).toBe(e.trim());
  });

  test("review prose that begins with SEVERITY: survives", () => {
    // #given a finding that discusses the gate contract in its own prose
    const prose = `SEVERITY: lines are the gate's input — the plan never says who emits them.`;
    const e = envelope([prose, "", `SEVERITY: {"maxSeverity":"P1","p0Count":0,"p1Count":1}`, "Review complete"]);

    // #when the envelope is prepared for the work prompt
    const stripped = stripSeverityLine(e);

    // #then only the machine line in the protected slot is gone
    expect(stripped).toContain(prose);
    expect(stripped).not.toContain(`SEVERITY: {`);
  });

  test("strips the machine line when the envelope has no terminal line", () => {
    // #given a leg that emitted the summary but not `Review complete`
    const e = envelope([`SEVERITY: {"maxSeverity":"NONE","p0Count":0,"p1Count":0}`]);

    // #when / #then the machine line still must not reach the work agent
    expect(stripSeverityLine(e)).not.toContain("SEVERITY:");
  });

  test("leaves a trailing prose line that merely mentions the marker", () => {
    // #given the last line is prose, not the machine line
    const e = envelope(["SEVERITY: markers were absent from both legs.", "Review complete"]);

    // #when / #then position decides, and this position holds prose
    expect(stripSeverityLine(e)).toContain("markers were absent from both legs.");
  });
});
