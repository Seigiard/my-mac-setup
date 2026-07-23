// Pure gate predicates for se-pipeline (KTD3): stage-boundary code evaluates
// external effects (validate-cmd, git rev-parse) and passes results in; these
// functions only classify. Degraded ≠ failed ≠ green: an unreadable envelope
// is degraded (needs a human), a broken contract is failed (retry/approval).
import { createHash } from "node:crypto";
import type { SecretScanResult } from "./envelopes.ts";

export type GateState = "green" | "failed" | "degraded";

export interface GateResult {
  state: GateState;
  reasons: string[];
  p1Count?: number;
}

export type PlanGateResult = { ok: true; hash: string } | { ok: false; reason: string };

export interface DocReviewStageOutput {
  claudeStatus?: string;
  opencodeStatus?: string;
}

export interface WorkGateInput {
  raw: string | undefined;
  baseTree: string;
  headTree: string;
  validateExitCode: number | null;
}

export interface CodeReviewGateInput {
  raw: string | undefined;
}

export interface RescanReport {
  moved: boolean;
  scan?: SecretScanResult;
  validateExitCode?: number | null;
  scannedHead?: string;
  currentHead?: string;
  // Diff base actually scanned: scannedHead when ancestry held (operator's new
  // commits only — an already-waived base..scannedHead finding must not
  // re-flag), else the full baseSha fallback (rebase/amend fail-closed).
  scanBase?: string;
}

export interface RescanGateInput {
  raw: string | undefined;
}

function frontmatterField(markdown: string, field: string): string | undefined {
  const fm = markdown.match(/^---\n([\s\S]*?)\n---/);
  if (!fm) return undefined;
  const line = fm[1].split("\n").find((l) => l.startsWith(`${field}:`));
  return line?.slice(field.length + 1).trim();
}

export function planGate(markdown: string, until: string): PlanGateResult {
  if (until === "pr") {
    return { ok: false, reason: "--until=pr is not implemented in the MVP; use --until=branch (KTD/R6)." };
  }
  if (until !== "branch") {
    return { ok: false, reason: `unknown --until value "${until}"; expected branch|pr.` };
  }
  const readiness = frontmatterField(markdown, "artifact_readiness");
  const execution = frontmatterField(markdown, "execution");
  if (readiness === undefined && execution === undefined) {
    return { ok: false, reason: "plan has no YAML frontmatter with artifact_readiness/execution — not a ce-unified-plan/v1 artifact." };
  }
  if (readiness !== "implementation-ready") {
    return { ok: false, reason: `plan artifact_readiness is "${readiness ?? "<missing>"}"; the pipeline requires implementation-ready (R1/AE4).` };
  }
  if (execution !== "code") {
    return { ok: false, reason: `plan execution is "${execution ?? "<missing>"}"; the pipeline requires execution: code (R1).` };
  }
  return { ok: true, hash: createHash("sha256").update(markdown).digest("hex") };
}

export function docReviewGate(output: DocReviewStageOutput | undefined): GateResult {
  if (!output) {
    return { state: "failed", reasons: ["verify-doc stage produced no output (crash or timeout)"] };
  }
  const claudeOk = output.claudeStatus === "ok";
  const opencodeOk = output.opencodeStatus === "ok";
  if (!claudeOk && !opencodeOk) {
    return { state: "degraded", reasons: ["both external envelopes unavailable (claude and opencode failed) — not a silent pass"] };
  }
  const reasons: string[] = [];
  if (!claudeOk) reasons.push("claude envelope missing (advisory — review is non-blocking for work)");
  if (!opencodeOk) reasons.push("opencode envelope missing (advisory — review is non-blocking for work)");
  return { state: "green", reasons };
}

export function workGate(input: WorkGateInput): GateResult {
  if (input.raw === undefined) {
    return { state: "failed", reasons: ["work stage produced no envelope (crash or timeout) — straight to Approval per KTD5"] };
  }
  let env: Record<string, unknown>;
  try {
    env = JSON.parse(input.raw) as Record<string, unknown>;
  } catch {
    return { state: "degraded", reasons: ["work envelope is not parseable JSON"] };
  }
  const reasons: string[] = [];
  if (env.status !== "complete") {
    reasons.push(`envelope status is "${String(env.status)}", expected "complete"`);
  }
  const evidence = env.verification_evidence;
  if (!Array.isArray(evidence) || evidence.length === 0) {
    reasons.push("verification_evidence is empty — self-report has no proof");
  }
  // Proof of work under jj-backed <Worktree> (KTD14): the worktree's tree-object
  // hash must differ from the base tree. git dirty-state (`status --porcelain`)
  // and commit SHAs are unreliable — jj continuously snapshots the working copy,
  // so a dirty tree reads clean and HEAD moves on its own. Comparing tree hashes
  // (content) is snapshot-independent. envelope.final_commit_sha is advisory now.
  if (input.baseTree === input.headTree) {
    reasons.push("worktree tree hash equals base — no content change, agent produced no work (KTD14)");
  }
  if (input.validateExitCode === null) {
    reasons.push("validate-cmd was not executed — agent self-report is not ground truth (KTD3)");
  } else if (input.validateExitCode !== 0) {
    reasons.push(`validate-cmd exited with code ${input.validateExitCode}`);
  }
  return reasons.length > 0 ? { state: "failed", reasons } : { state: "green", reasons: [] };
}

export function codeReviewGate(input: CodeReviewGateInput): GateResult {
  if (input.raw === undefined) {
    return { state: "failed", reasons: ["verify-code stage produced no report (crash or timeout)"] };
  }
  let report: Record<string, unknown>;
  try {
    report = JSON.parse(input.raw) as Record<string, unknown>;
  } catch {
    return { state: "degraded", reasons: ["review report is not parseable JSON"] };
  }
  const findings = report.findings;
  if (!Array.isArray(findings)) {
    return { state: "degraded", reasons: ["review report has no findings array — invalid envelope, not a silent pass"] };
  }
  // Multi-leg merged reports (lib/review-merge.ts) carry per-leg statuses.
  // Mirror docReviewGate: every leg failed is degraded (not a silent pass),
  // one failed leg is an advisory reason on an otherwise-green verdict.
  // Reports without a legs field (single-leg, smoke) keep the old behavior.
  const advisory: string[] = [];
  const legs = report.legs;
  if (legs !== null && typeof legs === "object" && !Array.isArray(legs)) {
    const entries = Object.entries(legs as Record<string, unknown>);
    const failed = entries.filter(([, status]) => status !== "ok").map(([source]) => source);
    if (entries.length > 0 && failed.length === entries.length) {
      return { state: "degraded", reasons: [`all review legs failed (${failed.join(", ")}) — not a silent pass`] };
    }
    for (const source of failed) advisory.push(`${source} review leg failed (advisory — remaining leg carried the review)`);
  }
  const severityCount = (sev: string): number =>
    findings.filter((f) => typeof f === "object" && f !== null && String((f as Record<string, unknown>).severity).toUpperCase() === sev).length;
  const p0Count = severityCount("P0");
  const p1Count = severityCount("P1");
  if (p0Count > 0) {
    return { state: "failed", reasons: [`${p0Count} P0 finding(s) — gate requires P0 = 0 (KTD3)`, ...advisory], p1Count };
  }
  return { state: "green", reasons: advisory, p1Count };
}

// Post-approval rescan verdict (R3–R5): commits an operator adds during a
// verify-code pause bypass the earlier secret-scan and validate-cmd. When the
// branch HEAD moved, the rescan attempt re-runs both and passes the report
// here. Unmoved HEAD is a deterministic no-op green (R5). Fail-closed: a leak
// or scanner crash is degraded (needs a human), a broken/absent validate or an
// absent/unparseable report is failed — no result is never a pass (R3, KTD3).
export function rescanGate(input: RescanGateInput): GateResult {
  if (input.raw === undefined) {
    return { state: "failed", reasons: ["rescan produced no report (crash or timeout) — no result is never a pass (R3)"] };
  }
  let report: RescanReport;
  try {
    report = JSON.parse(input.raw) as RescanReport;
  } catch {
    return { state: "failed", reasons: ["rescan report is not parseable JSON — no result is never a pass (R3)"] };
  }
  if (!report.moved) {
    return { state: "green", reasons: [] };
  }
  const headInfo = report.currentHead ? ` (HEAD ${report.currentHead.slice(0, 12)})` : "";
  if (!report.scan) {
    return { state: "failed", reasons: [`rescan report missing secret-scan result${headInfo} — fail-closed (R3)`] };
  }
  if (report.scan.state === "found") {
    return { state: "degraded", reasons: [`rescan secret-scan found leaks in operator commits${headInfo}: ${report.scan.details.slice(0, 500)}`] };
  }
  if (report.scan.state === "error") {
    return { state: "degraded", reasons: [`rescan secret-scan could not run${headInfo}: ${report.scan.details.slice(0, 500)}`] };
  }
  if (report.validateExitCode === undefined || report.validateExitCode === null) {
    return { state: "failed", reasons: [`validate-cmd was not executed on the moved HEAD${headInfo} — agent self-report is not ground truth (KTD3)`] };
  }
  if (report.validateExitCode !== 0) {
    return { state: "failed", reasons: [`validate-cmd exited with code ${report.validateExitCode} on the moved HEAD${headInfo}`] };
  }
  return { state: "green", reasons: [`operator commits rescanned clean${headInfo}`] };
}
