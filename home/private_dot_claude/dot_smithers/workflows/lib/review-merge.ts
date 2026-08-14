// Deterministic synthesis of the verify-code review legs (claude + opencode).
// The gate only counts P0/P1 findings, so an LLM synthesis step would add a
// timeout/envelope failure mode for zero gate value — merge in code, keep the
// full per-leg reports on disk for the human at the Approval pause. Fail-closed
// contract with codeReviewGate: a leg whose report is missing, unparseable, or
// lacks a findings array is recorded as failed in `legs`; the gate turns
// all-legs-failed into degraded and a single failed leg into an advisory
// reason (mirrors docReviewGate).
import { isUsableReviewLegStatus } from "./review-schema.ts";

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
    // An explicitly failed or still-running status ("failed",
    // "waiting_for_reviewers", any progress state salvaged from a session that
    // died before synthesis) is a dead leg wearing a valid shape — its findings
    // are partial at best. A status the vocabulary simply does not recognise is
    // NOT that: the parsed findings array above is the evidence the leg ran.
    if (!isUsableReviewLegStatus(report.status)) return { source: leg.source, ok: false, findings: [] };
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

// se-simplify synthesis (R4). Unlike mergeReviewReports (which flattens by
// source tag and does NO proximity detection — its findings feed a P0/P1 count,
// not an auto-apply), this merge decides what a downstream leg will AUTO-APPLY,
// so it must detect cross-model agreement explicitly. It reuses the same
// fail-closed parseLeg (a missing/garbage/no-findings leg is recorded failed,
// never throws) but adds a stated matching algorithm:
//   two findings MATCH when same file + line within LINE_PROXIMITY lines + a
//   token-Jaccard similarity on description+suggested_change ≥ SIMILARITY_MATCH.
// Matched across ≥2 sources → consensus (safest to auto-apply). Co-located
// (same file, within proximity) but NOT similar → contradiction: the legs
// target the same spot with different edits, which clash on a batch apply and
// signal disagreement — demoted to advisory, EXCLUDED from the apply set. A
// finding with no co-located counterpart → unique (attributed, still applied).
// Fail-closed tail: zero successful legs → status "degraded", empty apply set.
// One surviving leg → its findings are unique (usable), status "ok" with a
// no-cross-model-consensus reason; contradictions need ≥2 legs by construction.
const LINE_PROXIMITY = 3;
const SIMILARITY_MATCH = 0.3;
const STOPWORDS = new Set(["the", "a", "an", "to", "of", "and", "or", "is", "it", "in", "on", "for", "with", "this", "that", "be", "as", "by"]);

export interface SimplifyFinding {
  file: string;
  line: number;
  dimension?: string;
  description: string;
  suggested_change: string;
  sources: string[];
}

export interface SimplifyContradiction {
  file: string;
  line: number;
  entries: SimplifyFinding[];
}

export interface SimplifyMergeResult {
  status: "ok" | "degraded";
  legs: Record<string, "ok" | "failed">;
  consensus: SimplifyFinding[];
  unique: SimplifyFinding[];
  contradictions: SimplifyContradiction[];
  applySet: SimplifyFinding[];
  reasons: string[];
}

interface Candidate {
  file: string;
  line: number;
  dimension?: string;
  description: string;
  suggested_change: string;
  source: string;
}

function coerceCandidate(raw: unknown, source: string): Candidate | undefined {
  if (typeof raw !== "object" || raw === null) return undefined;
  const f = raw as Record<string, unknown>;
  const file = typeof f.file === "string" ? f.file : undefined;
  const suggested = typeof f.suggested_change === "string" ? f.suggested_change : "";
  const description = typeof f.description === "string" ? f.description : "";
  if (!file || (suggested === "" && description === "")) return undefined;
  const line = typeof f.line === "number" && Number.isFinite(f.line) ? f.line : 0;
  return {
    file,
    line,
    dimension: typeof f.dimension === "string" ? f.dimension : undefined,
    description,
    suggested_change: suggested,
    source,
  };
}

function tokenize(text: string): Set<string> {
  return new Set(
    text
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((t) => t.length >= 2 && !STOPWORDS.has(t)),
  );
}

function similarity(a: Candidate, b: Candidate): number {
  const ta = tokenize(`${a.description} ${a.suggested_change}`);
  const tb = tokenize(`${b.description} ${b.suggested_change}`);
  if (ta.size === 0 || tb.size === 0) return 0;
  let inter = 0;
  for (const t of ta) if (tb.has(t)) inter++;
  const union = ta.size + tb.size - inter;
  return union === 0 ? 0 : inter / union;
}

function colocated(a: Candidate, b: Candidate): boolean {
  return a.file === b.file && Math.abs(a.line - b.line) <= LINE_PROXIMITY;
}

function toFinding(sources: string[], anchor: Candidate): SimplifyFinding {
  return {
    file: anchor.file,
    line: anchor.line,
    dimension: anchor.dimension,
    description: anchor.description,
    suggested_change: anchor.suggested_change,
    sources,
  };
}

export function mergeSimplifyLegs(legs: ReviewLeg[]): SimplifyMergeResult {
  const parsed = legs.map(parseLeg);
  const legsStatus: Record<string, "ok" | "failed"> = Object.fromEntries(parsed.map((p) => [p.source, p.ok ? "ok" : "failed"]));
  const survivors = parsed.filter((p) => p.ok);
  const reasons: string[] = [];
  for (const p of parsed) if (!p.ok) reasons.push(`leg ${p.source} produced no usable findings (advisory)`);

  if (survivors.length === 0) {
    return { status: "degraded", legs: legsStatus, consensus: [], unique: [], contradictions: [], applySet: [], reasons: ["zero simplify legs succeeded — nothing to apply", ...reasons] };
  }

  const candidates: Candidate[] = survivors.flatMap((p) => p.findings.map((f) => coerceCandidate(f, p.source)).filter((c): c is Candidate => c !== undefined));
  const consumed = new Array<boolean>(candidates.length).fill(false);
  const consensus: SimplifyFinding[] = [];

  // Consensus pass: greedily pair the most-similar co-located findings from
  // DISTINCT sources. Best-match-first so a strong pair is not stolen by a
  // weaker co-located neighbour.
  for (let i = 0; i < candidates.length; i++) {
    if (consumed[i]) continue;
    let bestJ = -1;
    let bestSim = SIMILARITY_MATCH;
    for (let j = 0; j < candidates.length; j++) {
      if (consumed[j] || j === i || candidates[j].source === candidates[i].source) continue;
      if (!colocated(candidates[i], candidates[j])) continue;
      const sim = similarity(candidates[i], candidates[j]);
      if (sim >= bestSim) {
        bestSim = sim;
        bestJ = j;
      }
    }
    if (bestJ >= 0) {
      consumed[i] = true;
      consumed[bestJ] = true;
      const sources = Array.from(new Set([candidates[i].source, candidates[bestJ].source])).sort();
      consensus.push(toFinding(sources, candidates[i]));
    }
  }

  // Remaining findings: cluster co-located leftovers. A cluster spanning ≥2
  // distinct sources = contradiction (same spot, dissimilar edits → advisory,
  // excluded from apply). A single-source leftover = unique (applied).
  const remaining = candidates.map((c, idx) => ({ c, idx })).filter(({ idx }) => !consumed[idx]);
  const contradictions: SimplifyContradiction[] = [];
  const unique: SimplifyFinding[] = [];
  const clusterConsumed = new Array<boolean>(remaining.length).fill(false);

  for (let i = 0; i < remaining.length; i++) {
    if (clusterConsumed[i]) continue;
    const cluster = [remaining[i].c];
    clusterConsumed[i] = true;
    for (let j = i + 1; j < remaining.length; j++) {
      if (clusterConsumed[j]) continue;
      if (cluster.some((m) => colocated(m, remaining[j].c))) {
        cluster.push(remaining[j].c);
        clusterConsumed[j] = true;
      }
    }
    const distinctSources = new Set(cluster.map((c) => c.source));
    if (distinctSources.size >= 2) {
      contradictions.push({ file: cluster[0].file, line: cluster[0].line, entries: cluster.map((c) => toFinding([c.source], c)) });
    } else {
      for (const c of cluster) unique.push(toFinding([c.source], c));
    }
  }

  if (survivors.length === 1) reasons.push(`single simplify leg (${survivors[0].source}) survived — findings applied without cross-model consensus`);
  if (contradictions.length > 0) reasons.push(`${contradictions.length} contradictory location(s) excluded from apply (advisory only)`);

  const applySet = [...consensus, ...unique];
  return { status: "ok", legs: legsStatus, consensus, unique, contradictions, applySet, reasons };
}
