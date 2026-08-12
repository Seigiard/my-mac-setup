import { describe, expect, test } from "bun:test";

import { codeReviewGate } from "./gates.ts";
import { mergeReviewReports, mergeSimplifyLegs } from "./review-merge.ts";

function legReport(findings: unknown[]): string {
  return JSON.stringify({ status: "complete", verdict: "approve", findings });
}

describe("mergeReviewReports", () => {
  test("объединяет findings обоих плеч и тегирует source", () => {
    const merged = JSON.parse(
      mergeReviewReports([
        { source: "claude", raw: legReport([{ severity: "P0", title: "a" }]) },
        { source: "opencode", raw: legReport([{ severity: "P1", title: "b" }]) },
      ]),
    ) as { findings: Array<Record<string, unknown>>; legs: Record<string, string> };
    expect(merged.findings).toHaveLength(2);
    expect(merged.findings.map((f) => f.source).sort()).toEqual(["claude", "opencode"]);
    expect(merged.legs).toEqual({ claude: "ok", opencode: "ok" });
  });

  test("плечо без отчёта / с мусором / без findings → failed в legs, находки не теряются", () => {
    for (const bad of [undefined, "not json", JSON.stringify({ status: "complete" })]) {
      const merged = JSON.parse(
        mergeReviewReports([
          { source: "claude", raw: legReport([{ severity: "P1", title: "kept" }]) },
          { source: "opencode", raw: bad },
        ]),
      ) as { findings: unknown[]; legs: Record<string, string> };
      expect(merged.legs).toEqual({ claude: "ok", opencode: "failed" });
      expect(merged.findings).toHaveLength(1);
    }
  });

  test("сквозной контракт с codeReviewGate: оба плеча ок, P0=0 → green", () => {
    const merged = mergeReviewReports([
      { source: "claude", raw: legReport([{ severity: "P1", title: "x" }]) },
      { source: "opencode", raw: legReport([]) },
    ]);
    const r = codeReviewGate({ raw: merged });
    expect(r.state).toBe("green");
    expect(r.p1Count).toBe(1);
  });

  test("сквозной: P0 у одного плеча → failed", () => {
    const merged = mergeReviewReports([
      { source: "claude", raw: legReport([]) },
      { source: "opencode", raw: legReport([{ severity: "P0", title: "leak" }]) },
    ]);
    expect(codeReviewGate({ raw: merged }).state).toBe("failed");
  });

  test("сквозной: оба плеча failed → degraded, не green", () => {
    const merged = mergeReviewReports([
      { source: "claude", raw: undefined },
      { source: "opencode", raw: "garbage" },
    ]);
    const r = codeReviewGate({ raw: merged });
    expect(r.state).toBe("degraded");
    expect(r.reasons.join(" ")).toContain("claude");
    expect(r.reasons.join(" ")).toContain("opencode");
  });

  test("сквозной: одно плечо failed, выживший P0=0 → degraded (человеческий ack, F2/KTD-C)", () => {
    // #given the claude leg produced a report and opencode failed, no P0 among survivors
    const merged = mergeReviewReports([
      { source: "opencode", raw: legReport([]) },
      { source: "claude", raw: undefined },
    ]);
    const r = codeReviewGate({ raw: merged });
    // #then the surviving clean leg is not a silent pass — the dead leg's view is missing
    expect(r.state).toBe("degraded");
    expect(r.reasons.join(" ")).toContain("claude");
  });
});

function simplifyLeg(findings: unknown[]): string {
  return JSON.stringify({ status: "reviewers complete", findings });
}

describe("mergeSimplifyLegs", () => {
  test("both legs propose the same fix at the same location → consensus, applied once", () => {
    // #given two legs independently flag the same duplicate loop with the same fix
    const finding = {
      file: "util.js",
      line: 9,
      dimension: "reuse",
      description: "sumAgain duplicates sum, reimplements array reduce loop",
      suggested_change: "replace the manual loop with Array reduce and delete the duplicate function",
    };
    const merged = mergeSimplifyLegs([
      { source: "claude", raw: simplifyLeg([finding]) },
      { source: "opencode", raw: simplifyLeg([finding]) },
    ]);
    // #then it is consensus (both sources), in the apply set exactly once
    expect(merged.status).toBe("ok");
    expect(merged.consensus).toHaveLength(1);
    expect(merged.consensus[0].sources.sort()).toEqual(["claude", "opencode"]);
    expect(merged.applySet).toHaveLength(1);
    expect(merged.contradictions).toHaveLength(0);
  });

  test("a finding from only one leg → unique, still applied", () => {
    // #given claude flags one thing, opencode flags a different, distant thing
    const merged = mergeSimplifyLegs([
      { source: "claude", raw: simplifyLeg([{ file: "a.js", line: 5, description: "verbose if/else", suggested_change: "collapse to boolean expression" }]) },
      { source: "opencode", raw: simplifyLeg([{ file: "b.js", line: 40, description: "unused import", suggested_change: "remove the unused import statement" }]) },
    ]);
    // #then both are unique (no co-located counterpart) and both in the apply set
    expect(merged.status).toBe("ok");
    expect(merged.unique).toHaveLength(2);
    expect(merged.consensus).toHaveLength(0);
    expect(merged.applySet).toHaveLength(2);
  });

  test("conflicting suggestions at the same location → contradiction, excluded from apply", () => {
    // #given both legs touch util.js line 9 but propose dissimilar, clashing edits
    const merged = mergeSimplifyLegs([
      { source: "claude", raw: simplifyLeg([{ file: "util.js", line: 9, description: "keep loop but rename variable", suggested_change: "rename total to accumulator for readability" }]) },
      { source: "opencode", raw: simplifyLeg([{ file: "util.js", line: 10, description: "eliminate the whole function", suggested_change: "delete this function entirely and inline its single caller" }]) },
    ]);
    // #then it is a contradiction (advisory) and NOT in the apply set
    expect(merged.contradictions).toHaveLength(1);
    expect(merged.contradictions[0].entries.length).toBeGreaterThanOrEqual(2);
    expect(merged.applySet).toHaveLength(0);
    expect(merged.reasons.join(" ")).toContain("excluded from apply");
  });

  test("malformed / missing leg → advisory, never throws; survivor still usable", () => {
    for (const bad of [undefined, "not json", JSON.stringify({ status: "x" })]) {
      const merged = mergeSimplifyLegs([
        { source: "claude", raw: simplifyLeg([{ file: "a.js", line: 3, description: "dead code", suggested_change: "remove the unreachable branch" }]) },
        { source: "opencode", raw: bad },
      ]);
      // #then the survivor's finding is kept as unique; opencode marked failed
      expect(merged.legs).toEqual({ claude: "ok", opencode: "failed" });
      expect(merged.applySet).toHaveLength(1);
      expect(merged.status).toBe("ok");
      expect(merged.reasons.join(" ")).toContain("single simplify leg");
    }
  });

  test("zero successful legs → explicit degraded, empty apply set", () => {
    const merged = mergeSimplifyLegs([
      { source: "claude", raw: undefined },
      { source: "opencode", raw: "garbage" },
    ]);
    // #then degraded, nothing to apply — never a clean success with an empty set
    expect(merged.status).toBe("degraded");
    expect(merged.applySet).toHaveLength(0);
    expect(merged.reasons.join(" ")).toContain("zero simplify legs");
  });
});

describe("parseLeg via mergeReviewReports — нетерминальный статус ноги", () => {
  test("нога со status waiting_for_reviewers считается failed, её findings отброшены", () => {
    const merged = JSON.parse(
      mergeReviewReports([
        { source: "claude", raw: JSON.stringify({ status: "waiting_for_reviewers", findings: [{ severity: "P0", title: "partial" }] }) },
        { source: "opencode", raw: JSON.stringify({ status: "complete", findings: [] }) },
      ]),
    );
    expect(merged.legs.claude).toBe("failed");
    expect(merged.legs.opencode).toBe("ok");
    expect(merged.findings).toHaveLength(0);
  });

  test("нога со status failed считается failed даже с валидной формой", () => {
    const merged = JSON.parse(
      mergeReviewReports([
        { source: "claude", raw: JSON.stringify({ status: "failed", findings: [] }) },
        { source: "opencode", raw: JSON.stringify({ status: "completed", findings: [{ severity: "P1" }] }) },
      ]),
    );
    expect(merged.legs.claude).toBe("failed");
    expect(merged.findings).toHaveLength(1);
  });

  test("терминальные варианты статуса проходят: complete/completed/ok/done/success", () => {
    for (const status of ["complete", "Completed", "ok", "done", "SUCCESS"]) {
      const merged = JSON.parse(mergeReviewReports([{ source: "leg", raw: JSON.stringify({ status, findings: [] }) }]));
      expect(merged.legs.leg).toBe("ok");
    }
  });
});
