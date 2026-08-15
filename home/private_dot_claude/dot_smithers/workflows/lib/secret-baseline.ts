// Per-repo baseline for the tier-2 (whole-tree) secret boundary.
//
// Why a baseline at all: a blanket full-tree refusal was measured and rejected.
// `gitleaks dir` over this repo returns dozens of findings, all fixtures or
// false positives (`workflows/lib/*.test.ts` planted keys, `configs/MTMR/items.json`);
// a gate that refuses on those blocks every run here and in any repo that
// carries a credential-shaped test fixture. The baseline records what a repo
// already looked like, so the gate refuses only on what a run ADDS to the tree.
//
// Why not `.gitleaksignore` in the target repo: the harnesses run against
// repositories that belong to other people and other agents, and a run that
// writes a policy file into the target changes that repo's content, its git
// status, and possibly its CI — for every future non-harness scan too. The
// baseline is harness state, so it lives with the harness state and the target
// repo stays untouched.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

export const DEFAULT_STATE_DIR = path.join(os.homedir(), ".claude", ".smithers", "state");

const BASELINE_SUBDIR = "secret-baseline";

// 12 hex chars of sha256 over the absolute repo root. Long enough that two of
// the operator's checkouts never collide; the basename prefix is what makes the
// file identifiable by eye when the operator prunes it.
const DIGEST_CHARS = 12;

export interface BaselineRef {
  // Absolute path of the baseline report — reported verbatim to the operator,
  // because pruning it is a manual action on this exact file.
  path: string;
  exists: boolean;
  // The repository the baseline is keyed to, after worktree resolution.
  repoRoot: string;
}

export interface BaselineFinding {
  // `<path>:<rule>:<line>` — gitleaks' own identity for a finding, and the only
  // field that matches across scans. Carries no secret material.
  fingerprint: string;
  description: string;
}

// The ONE repository a path belongs to.
//
// A pipeline run scans its own worktree (`workflows/.worktrees/<run>`), never
// the operator's checkout. Keying the baseline on that path would mint a fresh
// baseline per run — which means auto-capturing, and therefore auto-approving,
// every preexisting finding on every run: a gate that never refuses.
// --git-common-dir resolves a linked worktree back to the shared .git of the
// repository it was created from.
export function repoIdentity(repoPath: string): string {
  const common = execFileSync("git", ["-C", repoPath, "rev-parse", "--path-format=absolute", "--git-common-dir"], {
    encoding: "utf8",
    stdio: "pipe",
  }).trim();
  return path.dirname(common);
}

export function resolveBaseline(repoPath: string, opts: { stateDir?: string } = {}): BaselineRef {
  const repoRoot = repoIdentity(repoPath);
  const digest = createHash("sha256").update(repoRoot).digest("hex").slice(0, DIGEST_CHARS);
  const file = path.join(opts.stateDir ?? DEFAULT_STATE_DIR, BASELINE_SUBDIR, `${path.basename(repoRoot)}-${digest}.json`);
  return { path: file, exists: fs.existsSync(file), repoRoot };
}

// Promotes a just-written gitleaks report into the repo's baseline. Written
// even when the report is empty: the file's existence is the record that this
// repo was baselined, so the next run compares instead of capturing again.
export function captureBaseline(baselinePath: string, reportPath: string): void {
  fs.mkdirSync(path.dirname(baselinePath), { recursive: true });
  fs.copyFileSync(reportPath, baselinePath);
}

// A missing or unparseable report yields no findings rather than throwing: the
// caller already has gitleaks' exit code, which is the fail-closed signal. This
// function only supplies the human-readable names for a message.
export function readReportFindings(reportPath: string): BaselineFinding[] {
  let raw: string;
  try {
    raw = fs.readFileSync(reportPath, "utf8");
  } catch {
    return [];
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  return parsed.map((entry) => {
    const row = entry as { Fingerprint?: unknown; File?: unknown; RuleID?: unknown; StartLine?: unknown; Description?: unknown };
    const fingerprint =
      typeof row.Fingerprint === "string" && row.Fingerprint !== ""
        ? row.Fingerprint
        : `${String(row.File ?? "?")}:${String(row.RuleID ?? "?")}:${String(row.StartLine ?? "?")}`;
    return { fingerprint, description: typeof row.Description === "string" ? row.Description : "" };
  });
}

// Names findings by fingerprint only. The fingerprint is path/rule/line, so the
// message stays safe to persist into run summaries even without --redact.
export function describeFindings(findings: BaselineFinding[], limit = 10): string {
  if (findings.length === 0) return "(the scanner reported findings but wrote no readable report)";
  const shown = findings.slice(0, limit).map((f) => f.fingerprint);
  const rest = findings.length - shown.length;
  return `${shown.join(", ")}${rest > 0 ? ` (+${rest} more)` : ""}`;
}
