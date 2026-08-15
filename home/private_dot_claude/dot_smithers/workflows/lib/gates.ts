// Pure gate predicates for se-pipeline (KTD3): stage-boundary code evaluates
// external effects (validate-cmd, git rev-parse) and passes results in; these
// functions only classify. Degraded ≠ failed ≠ green: an unreadable envelope
// is degraded (needs a human), a broken contract is failed (retry/approval).
import { createHash } from "node:crypto";
import type { SecretScanResult } from "./envelopes.ts";
import type { SeveritySummary } from "./severity-summary.ts";
import { classifyValidateFailure, missingModuleName } from "./validate-probe.ts";

export type GateState = "green" | "failed" | "degraded";

export interface GateResult {
  state: GateState;
  reasons: string[];
  p1Count?: number;
  // Machine-readable cause on a non-green verdict so waive predicates key on it
  // instead of parsing reason strings (KTD-D/KTD-E): "severity" = a parsed P0
  // (waivable on verify-doc), "availability" = crash/both-legs-down (keeps the
  // extra-attempt path).
  cause?: "severity" | "availability";
}

export type PlanGateResult = { ok: true; hash: string } | { ok: false; reason: string };

export interface DocReviewStageOutput {
  claudeStatus?: string;
  opencodeStatus?: string;
  claudeSeverity?: SeveritySummary;
  opencodeSeverity?: SeveritySummary;
}

export interface WorkGateInput {
  raw: string | undefined;
  baseTree: string;
  headTree: string;
  validateExitCode: number | null;
  // Stdout+stderr of the validate-cmd, read only to tell "the runner is not
  // installed" apart from "the tests failed" — both exit non-zero, and 127
  // alone reads as a test failure to anyone who has not memorised shell codes.
  validateOutput?: string;
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

// The plan's identity for the whole run (KTD7): gate 0 records this hash, the
// work gate re-hashes the launcher's file against it, and staging verifies the
// frozen copy it hands the work agent with it. One function so the three can
// never drift into disagreeing about what "the plan" is.
export function planContentHash(markdown: string): string {
  return createHash("sha256").update(markdown).digest("hex");
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
  return { ok: true, hash: planContentHash(markdown) };
}

// Additive severity ladder (KTD-D): leg availability stays fail-closed exactly
// as before (no output → failed; both legs down → degraded), and everything
// below that is new blocking power that only ever ADDS to today's behavior. Any
// available leg with a parsed p0Count > 0 fails the gate (max-of-legs,
// fail-closed per R4); P1 is advisory (summed, never blocking); a missing or
// unparseable severity summary degrades that leg to leg-availability-only (R5).
export function docReviewGate(output: DocReviewStageOutput | undefined): GateResult {
  if (!output) {
    return { state: "failed", reasons: ["verify-doc stage produced no output (crash or timeout)"], cause: "availability" };
  }
  const claudeOk = output.claudeStatus === "ok";
  const opencodeOk = output.opencodeStatus === "ok";
  if (!claudeOk && !opencodeOk) {
    return { state: "degraded", reasons: ["both external envelopes unavailable (claude and opencode failed) — not a silent pass"], cause: "availability" };
  }

  const legs: Array<{ source: string; ok: boolean; severity?: SeveritySummary }> = [
    { source: "claude", ok: claudeOk, severity: output.claudeSeverity },
    { source: "opencode", ok: opencodeOk, severity: output.opencodeSeverity },
  ];

  const reasons: string[] = [];
  for (const leg of legs) {
    if (!leg.ok) reasons.push(`${leg.source} envelope missing (advisory — review is non-blocking for work)`);
  }

  const available = legs.filter((leg) => leg.ok);
  const p0Legs = available.filter((leg) => leg.severity !== undefined && leg.severity.p0Count > 0);
  let p1Count = 0;
  for (const leg of available) {
    if (leg.severity) p1Count += leg.severity.p1Count;
    else reasons.push(`${leg.source} severity summary missing (advisory — leg-availability-only for this leg, R5)`);
  }

  if (p0Legs.length > 0) {
    const detail = p0Legs.map((leg) => `${leg.source} reports ${leg.severity?.p0Count} P0`).join("; ");
    return { state: "failed", reasons: [`plan-review P0 blocks (${detail}) — gate requires P0 = 0 (R3/R4)`, ...reasons], p1Count, cause: "severity" };
  }
  return { state: "green", reasons, p1Count };
}

// bash reports a missing executable as `<shell>: <line>: <name>: command not
// found` and exits 127. runValidateCmd also returns 127 when it kills the
// command group on timeout, so the two are told apart by the output, never by
// the code alone. A broken module resolution exits 1, exactly like a failing
// assertion, and is told apart the same way.
const COMMAND_NOT_FOUND = /([^\s:]+):\s*command not found/i;

export function describeValidateFailure(exitCode: number, output?: string): string {
  if (output === undefined) {
    return exitCode === 127 ? "validate-cmd could not run (exit 127: command not found, or terminated before it started)" : `validate-cmd exited with code ${exitCode}`;
  }
  switch (classifyValidateFailure(exitCode, output)) {
    case "missing-runner":
      return `validate-cmd could not run: "${COMMAND_NOT_FOUND.exec(output)?.[1] ?? "the command"}" is not installed in the run worktree (exit 127) — this is a missing runner, not a failing test. A fresh worktree has no node_modules; provision it with --setup-cmd, or name a runner the package manager resolves`;
    case "missing-module": {
      const named = missingModuleName(output);
      return `validate-cmd failed to resolve ${named === null ? "a module" : `"${named}"`} (exit ${exitCode}) — this is the worktree's state, not a failing test. A fresh worktree has no built workspace dists; provision it with --setup-cmd, or scope --validate-cmd to what a bare checkout can run`;
    }
    case "timeout":
      return "validate-cmd was terminated before it finished (timeout or signal, reported as exit 127) — raise --validate-timeout-ms or scope the command narrower";
    default:
      return `validate-cmd exited with code ${exitCode}`;
  }
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
    reasons.push(describeValidateFailure(input.validateExitCode, input.validateOutput));
  }
  return reasons.length > 0 ? { state: "failed", reasons } : { state: "green", reasons: [] };
}

// Names the escape the work gate used to report as "agent produced no work"
// (run-1786717826270: the agent followed the launcher's absolute plan path,
// resolved every repository path against the MAIN checkout, and wrote both
// files there while its run branch stayed at the base commit). Staging records
// a digest of `git status --porcelain` in the target repo; the work gate
// re-reads it and passes both here.
//
// ADVISORY ONLY — the caller appends the reason and leaves the gate state
// alone. An operator editing their own checkout during a multi-hour run is
// ordinary, and a red gate on that costs a full extra work leg. Returns
// undefined when nothing moved, and when the staged digest is absent (a run
// resumed from a persisted row written before this field existed).
export function mainCheckoutEscapeReason(
  repoDir: string,
  stagedDigest: string | null | undefined,
  currentDigest: string,
): string | undefined {
  if (!stagedDigest || stagedDigest === currentDigest) return undefined;
  return `the target repository's main checkout at ${repoDir} gained uncommitted changes since staging — the work agent may have written OUTSIDE its worktree (run-1786717826270). Inspect \`git -C ${repoDir} status\` before re-running: the work you are missing from the run branch may be sitting there.`;
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
  // Availability is fail-closed: every leg failed is degraded (not a silent
  // pass). A blocking finding on any surviving leg fails regardless of leg
  // health. A partial leg failure with a clean survivor is NOT a silent
  // single-leg green: the dead leg's view is missing (an idle-killed but
  // healthy claude leg could have carried the only P0), so the gate degrades
  // for a human ack instead of passing on the survivor alone. No retry — that
  // reopens the budget incident (KTD-C); the run pauses, it does not re-bill.
  // Reports without a legs field (single-leg, smoke) keep the old behavior.
  let failedLegs: string[] = [];
  const legs = report.legs;
  if (legs !== null && typeof legs === "object" && !Array.isArray(legs)) {
    const entries = Object.entries(legs as Record<string, unknown>);
    failedLegs = entries.filter(([, status]) => status !== "ok").map(([source]) => source);
    if (entries.length > 0 && failedLegs.length === entries.length) {
      return { state: "degraded", reasons: [`all review legs failed (${failedLegs.join(", ")}) — not a silent pass`] };
    }
  }
  const severityCount = (sev: string): number =>
    findings.filter((f) => typeof f === "object" && f !== null && String((f as Record<string, unknown>).severity).toUpperCase() === sev).length;
  const p0Count = severityCount("P0");
  const p1Count = severityCount("P1");
  const legAdvisory = failedLegs.map((source) => `${source} review leg failed`);
  if (p0Count > 0) {
    return { state: "failed", reasons: [`${p0Count} P0 finding(s) — gate requires P0 = 0 (KTD3)`, ...legAdvisory], p1Count };
  }
  if (failedLegs.length > 0) {
    return {
      state: "degraded",
      reasons: [`review incomplete: ${failedLegs.join(", ")} leg(s) failed and the surviving leg found no P0 — needs human confirmation, not a silent single-leg pass (KTD-C)`],
      p1Count,
    };
  }
  return { state: "green", reasons: [], p1Count };
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
    return { state: "failed", reasons: [`${describeValidateFailure(report.validateExitCode)} on the moved HEAD${headInfo}`] };
  }
  return { state: "green", reasons: [`operator commits rescanned clean${headInfo}`] };
}
