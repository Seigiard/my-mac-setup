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
//
// Two tiers, because the range is smaller than what leaves the machine:
//   tier 1, preExternalRepoGate — base..snapshot, "did THIS work add a secret?"
//   tier 2, preExternalTreeGate — the whole tree at the snapshot commit, which
//           is what the legs actually get a checkout of, judged against a
//           per-repo baseline so a repo's existing fixtures do not block it.
import * as fs from "node:fs";
import * as path from "node:path";

import { exportTreeAt, secretScanDiff, secretScanPath, secretScanTree, type SecretScanResult, type TreeExport } from "./envelopes.ts";
import { captureBaseline, describeFindings, readReportFindings, resolveBaseline, type BaselineRef } from "./secret-baseline.ts";

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

export interface TreeSnapshotGateInput {
  // Any path inside the repository — a linked worktree is resolved back to the
  // repository it belongs to when the baseline is keyed.
  repo: string;
  // The commit whose tree the external legs get a checkout of.
  head: string;
  label: string;
  bin?: string;
  timeoutMs?: number;
  override?: boolean;
  // Injectable so tests never touch the operator's real state directory.
  stateDir?: string;
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

// Tier 2. Scans the WHOLE TREE at the snapshot commit — the tree an external
// leg gets a checkout of and can read file by file, which is strictly larger
// than any commit range. A secret committed on the base branch before the run
// started is in that checkout and no range scan ever sees it.
//
// Judged against a per-repo baseline (see secret-baseline.ts for where it lives
// and why not in the target repo). First run for a repo captures the baseline
// and passes with a loud note; later runs refuse only on findings the baseline
// does not already contain. Refusal wording and fail-closed behaviour are tier
// 1's, unchanged: an unscannable tree is a refusal, and nothing was sent.
export function preExternalTreeGate(input: TreeSnapshotGateInput): PreExternalVerdict {
  const what = `the ${input.label} snapshot TREE at ${input.head.slice(0, 12)}`;
  if (input.override ?? scanOverridden()) return overridden(input.label, what);
  if (input.head.trim() === "") {
    return { state: "refuse", reason: refusal(input.label, `no commit to export for ${what} — the tree would go out unscanned`) };
  }

  let baseline: BaselineRef;
  try {
    baseline = resolveBaseline(input.repo, { stateDir: input.stateDir });
  } catch (e) {
    return { state: "refuse", reason: refusal(input.label, `could not identify the repository at ${input.repo}: ${message(e)}`) };
  }

  let exported: TreeExport;
  try {
    exported = exportTreeAt(input.repo, input.head);
  } catch (e) {
    return { state: "refuse", reason: refusal(input.label, `could not export ${what} for scanning: ${message(e)}`) };
  }

  try {
    // Beside the export, never inside it — a report under the scan root would
    // be scanned as tree content on the next pass.
    const reportPath = path.join(exported.tmpRoot, "report.json");
    const scan = secretScanTree(exported.scanRoot, {
      bin: input.bin,
      timeoutMs: input.timeoutMs,
      reportPath,
      baselinePath: baseline.exists ? baseline.path : undefined,
    });
    if (scan.state === "error") {
      return {
        state: "refuse",
        reason: refusal(
          input.label,
          `whole-tree secret scan could NOT run over ${what}: ${scan.details.slice(0, DETAIL_LIMIT)}. Install it with \`brew install gitleaks\``,
        ),
      };
    }
    if (!baseline.exists) {
      const captured = readReportFindings(reportPath);
      try {
        captureBaseline(baseline.path, reportPath);
      } catch (e) {
        return { state: "refuse", reason: refusal(input.label, `could not write the tree-scan baseline to ${baseline.path}: ${message(e)}`) };
      }
      return {
        state: "pass",
        reason:
          `${input.label}: whole-tree secret scan CAPTURED A NEW BASELINE for ${baseline.repoRoot} — ` +
          `${captured.length} finding(s) written to ${baseline.path}. Every finding in that file is now INVISIBLE to future runs ` +
          `until the operator prunes it; review it and delete the entries that are real secrets rather than fixtures. ` +
          `This run passes on the baseline it just captured.`,
      };
    }
    if (scan.state === "found") {
      const fresh = readReportFindings(reportPath);
      return {
        state: "refuse",
        reason: refusal(
          input.label,
          `whole-tree secret scan FOUND ${fresh.length} finding(s) in ${what} that are NOT in the baseline ${baseline.path}: ` +
            `${describeFindings(fresh).slice(0, DETAIL_LIMIT)}`,
        ),
      };
    }
    return { state: "pass", reason: `${input.label}: whole-tree secret scan clean for ${what} against baseline ${baseline.path}` };
  } finally {
    // Also runs on the refusal path: an exported copy of a tree that carries a
    // secret must not outlive the decision to refuse it.
    fs.rmSync(exported.tmpRoot, { recursive: true, force: true });
  }
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

function message(e: unknown): string {
  return (e instanceof Error ? e.message : String(e)).slice(0, DETAIL_LIMIT);
}

function overridden(label: string, what: string): PreExternalVerdict {
  return {
    state: "pass",
    reason: `${label}: pre-external secret scan SKIPPED by operator (${SCAN_OVERRIDE_ENV} set) — ${what} goes to the external legs unscanned`,
  };
}
