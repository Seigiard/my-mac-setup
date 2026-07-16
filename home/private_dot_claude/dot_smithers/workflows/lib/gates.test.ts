import { describe, expect, test } from "bun:test";

import { codeReviewGate, docReviewGate, planGate, rescanGate, workGate } from "./gates.ts";

const validPlan = `---
title: Fixture - Plan
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

# Fixture
`;

const requirementsOnlyPlan = validPlan.replace("implementation-ready", "requirements-only");

function workEnvelope(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    status: "complete",
    plan_path: "/abs/plan.md",
    changed_files: ["src/a.ts"],
    u_ids_attempted: ["U1"],
    u_ids_completed: ["U1"],
    verification_results: { "bun test": "green" },
    verification_evidence: [{ unit: "U1", behavior_changed: true }],
    blockers: [],
    behavior_change: true,
    standalone_shipping_skipped: true,
    final_commit_sha: "a".repeat(40),
    ...overrides,
  });
}

function reviewReport(p0: number, p1: number): string {
  const findings = [
    ...Array.from({ length: p0 }, (_, i) => ({ severity: "P0", title: `p0-${i}` })),
    ...Array.from({ length: p1 }, (_, i) => ({ severity: "P1", title: `p1-${i}` })),
  ];
  return JSON.stringify({ status: "complete", verdict: p0 ? "request_changes" : "approve", findings });
}

describe("planGate (гейт-0, KTD7)", () => {
  test("валидный implementation-ready план → ok со стабильным hash", () => {
    const a = planGate(validPlan, "branch");
    const b = planGate(validPlan, "branch");
    if (!a.ok || !b.ok) throw new Error("expected ok");
    expect(a.hash).toMatch(/^[0-9a-f]{64}$/);
    expect(a.hash).toBe(b.hash);
  });

  test("requirements-only план → отказ с причиной (AE4)", () => {
    const r = planGate(requirementsOnlyPlan, "branch");
    expect(r.ok).toBe(false);
    if (r.ok) throw new Error("expected refusal");
    expect(r.reason).toContain("artifact_readiness");
  });

  test("execution != code → отказ", () => {
    const r = planGate(validPlan.replace("execution: code", "execution: knowledge-work"), "branch");
    expect(r.ok).toBe(false);
  });

  test("нет frontmatter → отказ", () => {
    const r = planGate("# just a doc\n", "branch");
    expect(r.ok).toBe(false);
  });

  test("--until=pr → явный отказ «не реализовано»", () => {
    const r = planGate(validPlan, "pr");
    expect(r.ok).toBe(false);
    if (r.ok) throw new Error("expected refusal");
    expect(r.reason).toContain("pr");
  });
});

describe("docReviewGate", () => {
  test("оба конверта ok → green", () => {
    const r = docReviewGate({ claudeStatus: "ok", opencodeStatus: "ok" });
    expect(r.state).toBe("green");
  });

  test("один конверт failed → green (advisory) с причиной", () => {
    const r = docReviewGate({ claudeStatus: "ok", opencodeStatus: "failed" });
    expect(r.state).toBe("green");
    expect(r.reasons.join(" ")).toContain("opencode");
  });

  test("оба конверта failed → degraded, не failed и не green", () => {
    const r = docReviewGate({ claudeStatus: "failed", opencodeStatus: "failed" });
    expect(r.state).toBe("degraded");
  });

  test("стадия без вывода (crash/timeout) → failed", () => {
    const r = docReviewGate(undefined);
    expect(r.state).toBe("failed");
  });
});

describe("workGate (KTD3, KTD14 tree-hash proof)", () => {
  const baseTree = "a".repeat(40);
  const headTree = "b".repeat(40);

  test("валидный конверт + tree изменился + validate-cmd 0 → green", () => {
    const r = workGate({ raw: workEnvelope(), baseTree, headTree, validateExitCode: 0 });
    expect(r.state).toBe("green");
  });

  test("verification_evidence пустое → failed с причиной", () => {
    const r = workGate({ raw: workEnvelope({ verification_evidence: [] }), baseTree, headTree, validateExitCode: 0 });
    expect(r.state).toBe("failed");
    expect(r.reasons.join(" ")).toContain("verification_evidence");
  });

  test("tree головы == base (нет изменений контента) → failed", () => {
    const r = workGate({ raw: workEnvelope(), baseTree, headTree: baseTree, validateExitCode: 0 });
    expect(r.state).toBe("failed");
    expect(r.reasons.join(" ")).toContain("tree hash");
  });

  test("jj-clean-tree обман не проходит: конверт complete, но tree не изменился → failed", () => {
    const r = workGate({ raw: workEnvelope({ final_commit_sha: "c".repeat(40) }), baseTree, headTree: baseTree, validateExitCode: 0 });
    expect(r.state).toBe("failed");
  });

  test("final_commit_sha теперь advisory: расходится с деревом, но tree изменён → green", () => {
    const r = workGate({ raw: workEnvelope({ final_commit_sha: "d".repeat(40) }), baseTree, headTree, validateExitCode: 0 });
    expect(r.state).toBe("green");
  });

  test("status != complete → failed", () => {
    const r = workGate({ raw: workEnvelope({ status: "blocked" }), baseTree, headTree, validateExitCode: 0 });
    expect(r.state).toBe("failed");
  });

  test("validate-cmd exit != 0 → failed", () => {
    const r = workGate({ raw: workEnvelope(), baseTree, headTree, validateExitCode: 2 });
    expect(r.state).toBe("failed");
    expect(r.reasons.join(" ")).toContain("validate");
  });

  test("validate-cmd не запускалась → failed, не green", () => {
    const r = workGate({ raw: workEnvelope(), baseTree, headTree, validateExitCode: null });
    expect(r.state).toBe("failed");
  });

  test("конверт-мусор (не парсится) → degraded, не failed и не green", () => {
    const r = workGate({ raw: "{truncated", baseTree, headTree, validateExitCode: 0 });
    expect(r.state).toBe("degraded");
  });

  test("стадия без конверта → failed (сразу Approval per KTD5)", () => {
    const r = workGate({ raw: undefined, baseTree, headTree, validateExitCode: null });
    expect(r.state).toBe("failed");
  });
});

describe("codeReviewGate", () => {
  test("P0=0 при 12×P1 → green с p1Count=12", () => {
    const r = codeReviewGate({ raw: reviewReport(0, 12) });
    expect(r.state).toBe("green");
    expect(r.p1Count).toBe(12);
  });

  test("P0>0 → failed с числом находок", () => {
    const r = codeReviewGate({ raw: reviewReport(2, 1) });
    expect(r.state).toBe("failed");
    expect(r.reasons.join(" ")).toContain("2");
  });

  test("конверт-мусор → degraded", () => {
    const r = codeReviewGate({ raw: "not json at all" });
    expect(r.state).toBe("degraded");
  });

  test("валидный JSON без findings → degraded (невалидный конверт, не тихий pass)", () => {
    const r = codeReviewGate({ raw: JSON.stringify({ status: "complete" }) });
    expect(r.state).toBe("degraded");
  });

  test("стадия без вывода → failed", () => {
    const r = codeReviewGate({ raw: undefined });
    expect(r.state).toBe("failed");
  });
});

describe("rescanGate (пост-approval пересканирование, R3/R4/R5)", () => {
  const rescanReport = (overrides: Record<string, unknown> = {}): string =>
    JSON.stringify({ moved: true, scan: { state: "clean", details: "" }, validateExitCode: 0, scannedHead: "a".repeat(40), currentHead: "b".repeat(40), ...overrides });

  test("HEAD не двигался → green без причин (AE3)", () => {
    const r = rescanGate({ raw: JSON.stringify({ moved: false, scannedHead: "a".repeat(40), currentHead: "a".repeat(40) }) });
    expect(r.state).toBe("green");
    expect(r.reasons).toEqual([]);
  });

  test("двигался, скан чист, validate 0 → green с информационной причиной", () => {
    const r = rescanGate({ raw: rescanReport() });
    expect(r.state).toBe("green");
    expect(r.reasons.length).toBe(1);
    expect(r.reasons.join(" ")).toContain("bbbbbbbb");
  });

  test("двигался, скан found → degraded с усечённым details (AE1)", () => {
    const r = rescanGate({ raw: rescanReport({ scan: { state: "found", details: "AKIA-redacted-leak" } }) });
    expect(r.state).toBe("degraded");
    expect(r.reasons.join(" ")).toContain("AKIA-redacted-leak");
  });

  test("двигался, скан error → degraded (краш сканера — никогда не pass)", () => {
    const r = rescanGate({ raw: rescanReport({ scan: { state: "error", details: "gitleaks missing" } }) });
    expect(r.state).toBe("degraded");
  });

  test("двигался, validate exit 3 → failed с кодом в причине (AE2)", () => {
    const r = rescanGate({ raw: rescanReport({ validateExitCode: 3 }) });
    expect(r.state).toBe("failed");
    expect(r.reasons.join(" ")).toContain("3");
  });

  test("двигался, validateExitCode null (не запускалась) → failed (KTD3)", () => {
    const r = rescanGate({ raw: rescanReport({ validateExitCode: null }) });
    expect(r.state).toBe("failed");
  });

  test("raw undefined → failed", () => {
    const r = rescanGate({ raw: undefined });
    expect(r.state).toBe("failed");
  });

  test("невалидный JSON → failed (нет результата ≠ pass)", () => {
    const r = rescanGate({ raw: "{truncated" });
    expect(r.state).toBe("failed");
  });
});
