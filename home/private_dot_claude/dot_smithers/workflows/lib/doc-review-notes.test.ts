import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { readDocReviewAdvisory, type DocReviewLegs } from "./doc-review-notes.ts";

const MACHINE_LINE = `SEVERITY: {"maxSeverity":"P0","p0Count":1,"p1Count":0}`;

function envelopeFile(body: string): string {
  const path = join(mkdtempSync(join(tmpdir(), "doc-review-notes-")), "envelope.md");
  writeFileSync(path, body);
  return path;
}

function legsWith(claudeBody: string, over: Partial<DocReviewLegs> = {}): DocReviewLegs {
  return {
    claudeStatus: "ok",
    claudeEnvelopePath: envelopeFile(claudeBody),
    claudeSeverity: { maxSeverity: "P0", p0Count: 1, p1Count: 0 },
    ...over,
  };
}

describe("readDocReviewAdvisory", () => {
  test("strips the machine SEVERITY line out of what the work agent reads", () => {
    // #given an envelope carrying findings and the gate's machine line
    const doc = legsWith(`# Review\n\nP2: the plan omits a rollback path.\n\n${MACHINE_LINE}\nReview complete`);

    // #when the advisory block is built for the work prompt
    const advisory = readDocReviewAdvisory(doc, false);

    // #then the finding is there and the gate input is not
    expect(advisory).toContain("the plan omits a rollback path");
    expect(advisory).not.toContain("SEVERITY: {");
  });

  test("prose beginning with SEVERITY: reaches the work agent intact", () => {
    // #given a finding whose own text opens with the marker word
    const prose = "SEVERITY: lines are unspecified — the plan never says who emits them.";
    const doc = legsWith(`# Review\n\n${prose}\n\n${MACHINE_LINE}\nReview complete`);

    // #when / #then losing this line loses the finding (docs/issues/2026-08-14-003)
    expect(readDocReviewAdvisory(doc, false)).toContain(prose);
  });

  test("a missing envelope degrades the text instead of throwing", () => {
    // #given a path that tmp-cleanup already removed
    const doc: DocReviewLegs = { claudeStatus: "ok", claudeEnvelopePath: "/nonexistent/envelope.md" };

    // #when / #then the advisory says so and the run continues
    expect(readDocReviewAdvisory(doc, false)).toContain("unavailable: /nonexistent/envelope.md");
  });

  test("no stage output yields no advisory block at all", () => {
    expect(readDocReviewAdvisory(undefined, false)).toBe("");
  });
});
