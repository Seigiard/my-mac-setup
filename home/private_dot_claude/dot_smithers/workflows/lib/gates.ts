// Pure gate predicates for se-pipeline (KTD3): stage-boundary code evaluates
// external effects (validate-cmd, git rev-parse) and passes results in; these
// functions only classify. Degraded ≠ failed ≠ green: an unreadable envelope
// is degraded (needs a human), a broken contract is failed (retry/approval).
import { createHash } from "node:crypto";

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
  headSha: string;
  validateExitCode: number | null;
}

export interface CodeReviewGateInput {
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
  const sha = env.final_commit_sha;
  if (typeof sha !== "string" || sha !== input.headSha) {
    reasons.push(`final_commit_sha ${typeof sha === "string" ? `"${sha}"` : "<missing>"} does not match branch HEAD ${input.headSha}`);
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
  const severityCount = (sev: string): number =>
    findings.filter((f) => typeof f === "object" && f !== null && String((f as Record<string, unknown>).severity).toUpperCase() === sev).length;
  const p0Count = severityCount("P0");
  const p1Count = severityCount("P1");
  if (p0Count > 0) {
    return { state: "failed", reasons: [`${p0Count} P0 finding(s) — gate requires P0 = 0 (KTD3)`], p1Count };
  }
  return { state: "green", reasons: [], p1Count };
}
