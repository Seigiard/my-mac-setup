// The pre-external secret boundary for the STANDALONE harnesses
// (se-code-review, se-simplify, se-doc-review). The se-pipeline scans the run
// branch diff before any repo content reaches an external LLM leg (KTD10); a
// harness run directly — outside the pipeline — had no such gate, and its
// `git stash create` snapshot goes to opencode via permission.external_directory.
//
// Policy: REFUSE, never filter. A hit stops the run before staging; dropping the
// offending file from the snapshot would instead hand the reviewers a tree that
// silently differs from the repo and a review claiming coverage it never had.
// A scanner that cannot run is also a refusal (fail-closed) — an unscanned
// snapshot is exactly the state this gate exists to prevent.
//
// Escape hatch: SE_SKIP_SECRET_SCAN=1 in the harness environment. It is the
// operator's deliberate, per-invocation stand-in for the pipeline's
// waive-on-approve, which standalone runs have no pause to offer.
import { secretScanDiff, secretScanPath, type SecretScanResult } from "./envelopes.ts";

export const SCAN_OVERRIDE_ENV = "SE_SKIP_SECRET_SCAN";

const DETAIL_LIMIT = 500;

export type PreExternalVerdict = { state: "pass" | "refuse"; reason: string };

export interface RepoSnapshotGateInput {
  repo: string;
  // Range start. Empty means the caller could not resolve a base commit, which
  // is a refusal: an unbounded or malformed range is not a scan.
  baseSha: string;
  // The commit the snapshot checks out — a `git stash create` commit when the
  // tree is dirty, else HEAD.
  head: string;
  label: string;
  bin?: string;
  timeoutMs?: number;
  override?: boolean;
}

export interface DocumentGateInput {
  docPath: string;
  label: string;
  bin?: string;
  timeoutMs?: number;
  override?: boolean;
}

// Scans baseSha..head in `repo`, including the stash snapshot's merge diff —
// without includeMergeDiffs a dirty tree scans zero commits and reports clean.
export function preExternalRepoGate(input: RepoSnapshotGateInput): PreExternalVerdict {
  const what = `the ${input.label} snapshot (${input.baseSha.slice(0, 12)}..${input.head.slice(0, 12)})`;
  if (input.override ?? scanOverridden()) return overridden(input.label, what);
  if (input.baseSha.trim() === "" || input.head.trim() === "") {
    return {
      state: "refuse",
      reason: refusal(
        input.label,
        `no commit range to scan (base "${input.baseSha}", head "${input.head}") — the snapshot would go out unscanned`,
      ),
    };
  }
  const scan = secretScanDiff(input.repo, input.baseSha, {
    bin: input.bin,
    timeoutMs: input.timeoutMs,
    head: input.head,
    includeMergeDiffs: true,
  });
  return verdictFor(scan, input.label, what);
}

// Scans the document itself (files on disk, not history): se-doc-review ships a
// copy of one plan/spec to the external legs, and a pasted credential in a plan
// is the whole payload. Measured false-positive cost on this repo's docs tree:
// zero findings over 591 KB.
export function preExternalDocGate(input: DocumentGateInput): PreExternalVerdict {
  const what = `the ${input.label} document ${input.docPath}`;
  if (input.override ?? scanOverridden()) return overridden(input.label, what);
  const scan = secretScanPath(input.docPath, { bin: input.bin, timeoutMs: input.timeoutMs });
  return verdictFor(scan, input.label, what);
}

export function scanOverridden(): boolean {
  const raw = process.env[SCAN_OVERRIDE_ENV];
  return raw !== undefined && raw !== "" && raw !== "0";
}

// Throws on a refusal so the harness's stage task fails before it copies the
// plugin skill, creates the snapshot worktree, or dispatches a leg. A pass is
// logged, so a run's own log carries the evidence that the gate ran.
export function enforcePreExternalGate(
  verdict: PreExternalVerdict,
  log: (message: string) => void = console.error,
): void {
  if (verdict.state === "refuse") throw new Error(verdict.reason);
  log(verdict.reason);
}

function verdictFor(scan: SecretScanResult, label: string, what: string): PreExternalVerdict {
  if (scan.state === "clean") return { state: "pass", reason: `${label}: pre-external secret scan clean for ${what}` };
  if (scan.state === "found") {
    return {
      state: "refuse",
      reason: refusal(label, `secret scan FOUND secrets in ${what}. Redacted findings: ${scan.details.slice(0, DETAIL_LIMIT)}`),
    };
  }
  return {
    state: "refuse",
    reason: refusal(
      label,
      `secret scan could NOT run over ${what}: ${scan.details.slice(0, DETAIL_LIMIT)}. Install it with \`brew install gitleaks\``,
    ),
  };
}

function refusal(label: string, detail: string): string {
  return `${label}: pre-external secret gate REFUSED — ${detail}. Nothing was sent to the external review legs (claude/opencode). Redact the secret and re-run, or re-run with ${SCAN_OVERRIDE_ENV}=1 to send it anyway.`;
}

function overridden(label: string, what: string): PreExternalVerdict {
  return {
    state: "pass",
    reason: `${label}: pre-external secret scan SKIPPED by operator (${SCAN_OVERRIDE_ENV} set) — ${what} goes to the external legs unscanned`,
  };
}
