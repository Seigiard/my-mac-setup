import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { docReviewSeverityStatusNote, docReviewWaiveNote, readDocReviewAdvisory, type DocReviewLegs } from "./doc-review-notes.ts";

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

  test("a waived run tells the work agent the P0 was overridden", () => {
    // #given the operator waived a parsed P0
    const doc = legsWith(`# Review\n\nP0: the migration has no rollback.\n\n${MACHINE_LINE}\nReview complete`);

    // #when the advisory is built with the waive flag
    const advisory = readDocReviewAdvisory(doc, true);

    // #then it states the override rather than reading as a clean run
    expect(advisory).toContain("explicitly waived it");
    expect(advisory).toContain("known accepted risk");
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

describe("docReviewSeverityStatusNote", () => {
  test("records the parsed counts per leg", () => {
    const doc = legsWith("# Review\nReview complete", { opencodeStatus: "ok", opencodeSeverity: { maxSeverity: "NONE", p0Count: 0, p1Count: 0 } });
    expect(docReviewSeverityStatusNote(doc)).toBe(
      "verify-doc severity: claude maxSeverity=P0 P0=1 P1=0; opencode maxSeverity=NONE P0=0 P1=0",
    );
  });

  test("distinguishes a dead leg from a leg whose summary did not parse", () => {
    // #given one leg down and one leg up without a parsed summary
    const doc: DocReviewLegs = { claudeStatus: "failed", opencodeStatus: "ok" };

    // #when / #then the two states must not read the same — a systemic prompt
    // failure (all legs missing SEVERITY) has to be visible in the notes
    const note = docReviewSeverityStatusNote(doc);
    expect(note).toContain("claude leg unavailable");
    expect(note).toContain("opencode severity missing (advisory)");
  });

  test("no stage output is stated, not guessed", () => {
    expect(docReviewSeverityStatusNote(undefined)).toBe("verify-doc severity: no stage output");
  });
});

describe("docReviewWaiveNote", () => {
  test("the durable excerpt carries the finding without the raw machine line", () => {
    // #given a waived run whose envelope ends with the gate's machine line
    const doc = legsWith(`# Review\n\nP0: the migration has no rollback.\n\n${MACHINE_LINE}\nReview complete`);

    // #when the waive note is built for summary.notes
    const note = docReviewWaiveNote(doc, "operator accepted the risk");

    // #then the content survives the loss of /tmp, and the line the reader
    // already sees parsed above is not repeated raw (docs/issues/2026-08-14-003)
    expect(note).toContain("P0: the migration has no rollback.");
    expect(note).toContain("operator accepted the risk");
    expect(note).toContain("maxSeverity=P0 P0=1 P1=0");
    expect(note).not.toContain("SEVERITY: {");
  });

  test("a lost envelope leaves the decision recorded anyway", () => {
    // #given tmp-cleanup removed the envelope before the waive
    const doc: DocReviewLegs = { claudeStatus: "ok", claudeEnvelopePath: "/nonexistent/envelope.md" };

    // #when / #then the waiver itself is what must survive
    const note = docReviewWaiveNote(doc, "accepted");
    expect(note).toContain("P0 waived by operator — accepted");
    expect(note).not.toContain("envelope excerpt");
  });
});
