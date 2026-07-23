import { describe, expect, test } from "bun:test";

import { codeReviewGate } from "./gates.ts";
import { mergeReviewReports } from "./review-merge.ts";

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

  test("сквозной: одно плечо failed, P0=0 → green с advisory-пометкой", () => {
    const merged = mergeReviewReports([
      { source: "claude", raw: legReport([]) },
      { source: "opencode", raw: undefined },
    ]);
    const r = codeReviewGate({ raw: merged });
    expect(r.state).toBe("green");
    expect(r.reasons.join(" ")).toContain("opencode");
  });
});
