// Deterministic synthesis of the verify-code review legs (claude + opencode).
// The gate only counts P0/P1 findings, so an LLM synthesis step would add a
// timeout/envelope failure mode for zero gate value — merge in code, keep the
// full per-leg reports on disk for the human at the Approval pause. Fail-closed
// contract with codeReviewGate: a leg whose report is missing, unparseable, or
// lacks a findings array is recorded as failed in `legs`; the gate turns
// all-legs-failed into degraded and a single failed leg into an advisory
// reason (mirrors docReviewGate).
export interface ReviewLeg {
  source: string;
  raw: string | undefined;
}

interface ParsedLeg {
  source: string;
  ok: boolean;
  findings: unknown[];
}

function parseLeg(leg: ReviewLeg): ParsedLeg {
  if (leg.raw === undefined) return { source: leg.source, ok: false, findings: [] };
  try {
    const report = JSON.parse(leg.raw) as Record<string, unknown>;
    if (!Array.isArray(report.findings)) return { source: leg.source, ok: false, findings: [] };
    return { source: leg.source, ok: true, findings: report.findings };
  } catch {
    return { source: leg.source, ok: false, findings: [] };
  }
}

export function mergeReviewReports(legs: ReviewLeg[]): string {
  const parsed = legs.map(parseLeg);
  const findings = parsed.flatMap((p) =>
    p.findings.map((f) => (typeof f === "object" && f !== null ? { ...(f as Record<string, unknown>), source: p.source } : f)),
  );
  const legsStatus = Object.fromEntries(parsed.map((p) => [p.source, p.ok ? "ok" : "failed"]));
  return JSON.stringify({ status: "complete", findings, legs: legsStatus });
}
