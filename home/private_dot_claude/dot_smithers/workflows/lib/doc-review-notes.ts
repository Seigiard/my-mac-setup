// Human- and agent-facing text built from the verify-doc stage output: the
// advisory block echoed into the work prompt, the per-leg severity read, and
// the durable waive note. Kept out of se-pipeline.tsx so the wiring that
// consumes lib/severity-summary.ts is unit-testable without a Smithers runtime
// — the gap that let three P2 defects sit unnoticed
// (docs/issues/2026-08-14-003).
//
// Envelope files live in /tmp and a resume after tmp-cleanup loses them, so
// every read here is fail-soft: a missing envelope degrades the text, never the
// run.
import * as fs from "node:fs";

import { stripSeverityLine, type SeveritySummary } from "./severity-summary.ts";

// Structural mirror of se-pipeline's docReview output. Declared here rather
// than imported so this module has no dependency back on the workflow file.
export interface DocReviewLegs {
  claudeStatus?: string | null;
  opencodeStatus?: string | null;
  claudeEnvelopePath?: string | null;
  opencodeEnvelopePath?: string | null;
  claudeSeverity?: SeveritySummary | null;
  opencodeSeverity?: SeveritySummary | null;
}

// Advisory envelopes are echoed whole into the work prompt; the cap keeps a
// pathological review from crowding out the plan itself (opencode's P2s once
// predicted a spec failure the work leg then had to rediscover, so the content
// earns its space).
const ADVISORY_CAP = 12_000;
const WAIVE_EXCERPT_CAP = 800;

function legs(doc: DocReviewLegs): Array<[string, string | undefined]> {
  return [
    ["claude", doc.claudeEnvelopePath ?? undefined],
    ["opencode", doc.opencodeEnvelopePath ?? undefined],
  ];
}

export function legSeverityLabel(status: string | undefined, severity: SeveritySummary | undefined): string {
  if (status !== "ok") return "leg unavailable";
  if (!severity) return "severity missing (advisory)";
  return `maxSeverity=${severity.maxSeverity} P0=${severity.p0Count} P1=${severity.p1Count}`;
}

// KTD-D observability: every run records per-leg severity-parse status so a
// systemic prompt-contract failure (all legs missing the SEVERITY line) is
// visible in the durable notes and verify-doc.result.json instead of silently
// draining the gate's blocking power.
export function docReviewSeverityStatusNote(doc: DocReviewLegs | undefined): string {
  if (!doc) return "verify-doc severity: no stage output";
  return `verify-doc severity: claude ${legSeverityLabel(doc.claudeStatus ?? undefined, doc.claudeSeverity ?? undefined)}; opencode ${legSeverityLabel(doc.opencodeStatus ?? undefined, doc.opencodeSeverity ?? undefined)}`;
}

export function readDocReviewAdvisory(doc: DocReviewLegs | undefined, waived: boolean): string {
  if (!doc) return "";
  const sections: string[] = [];
  for (const [source, envelopePath] of legs(doc)) {
    if (!envelopePath) continue;
    try {
      // Strip the SEVERITY machine line — it is gate input, not review content
      // the work agent should act on (Assumptions item 2 / U4 hygiene).
      const text = stripSeverityLine(fs.readFileSync(envelopePath, "utf8"));
      if (text === "") continue;
      const capped = text.length > ADVISORY_CAP ? `${text.slice(0, ADVISORY_CAP)}\n[... truncated]` : text;
      sections.push(`--- ${source} doc-review envelope ---\n${capped}`);
    } catch {
      sections.push(`--- ${source} doc-review envelope --- (unavailable: ${envelopePath})`);
    }
  }
  if (sections.length === 0) return "";
  // The work agent must see the same decision context the operator saw: the
  // gate's severity read and, on a waived run, the fact that a P0 was found
  // and explicitly overridden — not a generic clean-run disclaimer.
  const waiveLine = waived
    ? "\n\nIMPORTANT: the verify-doc gate FAILED on a parsed P0 in these reviews and the operator explicitly waived it (se approve). Treat the P0 finding(s) below as known accepted risk: implement with them in mind and record in your envelope's notes how each was addressed or why it remains accepted."
    : "";
  return `

ADVISORY plan-review findings (verify-doc stage, two independent external reviews). The stage gate blocks on parsed P0 findings; what reaches you here is below the blocking bar (P1/P2), from a leg whose severity summary did not parse, or explicitly waived by the operator. Gate read: ${docReviewSeverityStatusNote(doc)}.${waiveLine}

For each finding that touches a unit you implement: address it or consciously reject it, and record material rejections in the envelope's notes.

${sections.join("\n\n")}`;
}

// KTD-E: a waived P0 spec flaw lives only in /tmp envelope files that a resume
// after tmp-cleanup loses. The durable waive note embeds the per-leg severity
// summaries, the gate reasons, and a trimmed fail-soft excerpt of each envelope
// — content, not just the decision — so the waiver survives in summary.notes.
//
// The excerpt is stripped before it is cut to length: the machine SEVERITY line
// is gate input that already appears in this note as a parsed per-leg label, so
// repeating it raw would confuse a reader and any parser of the note.
export function docReviewWaiveNote(doc: DocReviewLegs | undefined, reasons: string | undefined): string {
  const parts: string[] = [`verify-doc: P0 waived by operator — ${reasons ?? ""}`, docReviewSeverityStatusNote(doc)];
  for (const [source, envelopePath] of legs(doc ?? {})) {
    if (!envelopePath) continue;
    try {
      const excerpt = stripSeverityLine(fs.readFileSync(envelopePath, "utf8")).slice(0, WAIVE_EXCERPT_CAP);
      if (excerpt) parts.push(`${source} envelope excerpt: ${excerpt}`);
    } catch {
      // fail-soft: the envelope may be gone after tmp-cleanup
    }
  }
  return parts.join(" — ");
}
