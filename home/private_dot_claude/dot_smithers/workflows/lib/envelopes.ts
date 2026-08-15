// Work-stage boundary helpers (KTD3/KTD10/KTD13): parse the ce-work
// return-to-caller envelope, run the operator-supplied validate-cmd, and
// secret-scan what leaves the machine — the run branch diff (tier 1) and the
// whole snapshot tree the external legs can read (tier 2).
// These perform the external effects; the pure verdicts live in gates.ts.
import { execFileSync, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { z } from "zod/v4";

export const workEnvelopeSchema = z.object({
  status: z.string(),
  plan_path: z.string().optional(),
  changed_files: z.array(z.string()).default([]),
  u_ids_attempted: z.array(z.string()).default([]),
  u_ids_completed: z.array(z.string()).default([]),
  verification_results: z.unknown().optional(),
  verification_evidence: z.array(z.unknown()).default([]),
  blockers: z.array(z.unknown()).default([]),
  behavior_change: z.boolean().optional(),
  standalone_shipping_skipped: z.boolean().optional(),
  // Pipeline extension, not part of the documented skill contract (KTD13).
  final_commit_sha: z.string().optional(),
});

export type WorkEnvelope = z.infer<typeof workEnvelopeSchema>;

export type ParsedWorkEnvelope = { ok: true; envelope: WorkEnvelope } | { ok: false; reason: string };

export function parseWorkEnvelope(raw: string | undefined): ParsedWorkEnvelope {
  if (raw === undefined) {
    return { ok: false, reason: "no envelope produced by the work stage" };
  }
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch (e) {
    return { ok: false, reason: `envelope does not parse as JSON: ${e instanceof Error ? e.message : String(e)}` };
  }
  const parsed = workEnvelopeSchema.safeParse(data);
  if (!parsed.success) {
    return { ok: false, reason: `envelope violates the return-to-caller schema: ${parsed.error.message}` };
  }
  return { ok: true, envelope: parsed.data };
}

export interface ValidateCmdResult {
  exitCode: number;
  output: string;
}

// Node's spawnSync timeout signals only the direct child; a validate-cmd that
// spawned helpers (dev server, playwright workers) left them orphaned past the
// kill (seen live on PRD-2099). spawnSync has no `detached`, so the wrapper
// enables job control (`set -m`): the user command becomes a background job in
// its OWN process group, and the trap forwards the timeout signal to that
// whole group (kill -- -$!). It must be a background job under `wait` anyway —
// bash defers trap handling while a foreground child runs, so a foreground
// command would suppress the group kill until it exited on its own.
const GROUP_KILL_WRAPPER = `trap 'kill -KILL -- -$! 2>/dev/null' TERM INT; set -m; bash -lc "$1" & wait "$!"`;

export function runValidateCmd(cmd: string, cwd: string, timeoutMs = 10 * 60_000): ValidateCmdResult {
  const res = spawnSync("bash", ["-c", GROUP_KILL_WRAPPER, "se-validate", cmd], {
    cwd,
    encoding: "utf8",
    timeout: timeoutMs,
    killSignal: "SIGTERM",
  });
  const output = `${res.stdout ?? ""}${res.stderr ?? ""}`;
  if (res.error || res.status === null) {
    return { exitCode: 127, output: `${output}${res.error ? String(res.error) : "terminated (timeout or signal)"}` };
  }
  return { exitCode: res.status, output };
}

export type SecretScanState = "clean" | "found" | "error";

export interface SecretScanResult {
  state: SecretScanState;
  details: string;
}

// Scans a commit range (baseSha..head, head defaults to HEAD). Exit codes are
// pinned via --exit-code so a scanner crash is never confused with a clean
// pass: 0 clean, 2 leaks, anything else (missing binary, timeout, git errors) =
// error → degraded at the gate (KTD10).
//
// includeMergeDiffs is required whenever `head` is a `git stash create`
// snapshot: that snapshot is a MERGE commit, and `git log -p` prints no patch
// for merges, so the plain range scans 0 commits and reports clean while the
// uncommitted content goes out unscanned (measured on gitleaks 8.30.1).
// --diff-merges=first-parent diffs the stash against HEAD, which is exactly the
// working-tree changes the standalone harnesses ship to external agents.
export function secretScanDiff(
  repo: string,
  baseSha: string,
  opts: { bin?: string; timeoutMs?: number; head?: string; includeMergeDiffs?: boolean } = {},
): SecretScanResult {
  const range = `${baseSha}..${opts.head ?? "HEAD"}`;
  const logOpts = opts.includeMergeDiffs ? `${range} --diff-merges=first-parent` : range;
  return runGitleaks(["git", "--no-banner", "--redact", "--exit-code", "2", `--log-opts=${logOpts}`, repo], opts);
}

// Scans FILES ON DISK rather than git history. The doc-review harness ships a
// copy of one document, which may live outside any repository and never has a
// commit range to scan.
export function secretScanPath(target: string, opts: { bin?: string; timeoutMs?: number } = {}): SecretScanResult {
  return runGitleaks(["dir", "--no-banner", "--redact", "--exit-code", "2", target], opts);
}

// Scans a whole directory TREE, the tier-2 boundary: the external legs get a
// full checkout of the snapshot and can read every tracked file, including
// files no commit range touches (see docs/issues/2026-08-14-009).
//
// cwd = root, target "." is load-bearing, not style. A `dir` scan's fingerprints
// are relative to the target ARGUMENT: measured on gitleaks 8.30.1, the same
// tree scanned as `a` reports `a/sub/creds.txt:aws-access-token:1` and as `b`
// reports `b/sub/…`, so a baseline captured under one absolute root matches
// nothing under another — and every snapshot export lands in a fresh mkdtemp
// directory. Entering the root and passing "." yields `sub/creds.txt:…` from
// both, which is what makes a per-repo baseline reusable across runs.
export function secretScanTree(
  root: string,
  opts: { bin?: string; timeoutMs?: number; reportPath?: string; baselinePath?: string } = {},
): SecretScanResult {
  const args = ["dir", "--no-banner", "--redact", "--exit-code", "2"];
  if (opts.reportPath !== undefined) args.push("--report-format", "json", "--report-path", opts.reportPath);
  if (opts.baselinePath !== undefined) args.push("--baseline-path", opts.baselinePath);
  args.push(".");
  return runGitleaks(args, { ...opts, cwd: root });
}

export interface TreeExport {
  // Remove this whole directory when the scan is done — it holds the export and
  // any report written beside it.
  tmpRoot: string;
  // The scan root: the exported tree itself, with nothing else in it.
  scanRoot: string;
}

// Materializes the git tree at `sha` into a fresh temp directory.
//
// Not the live worktree: the pipeline's run worktree may have been provisioned
// by setupCmd (`bun install && turbo build`), so it carries node_modules and
// build output — scanning that is slow, noisy, and is not repository content.
// `git archive` emits exactly the tracked tree instead. The tar lands beside
// the scan root rather than inside it, so the scanner never reads its own input
// archive or the report written next to it.
export function exportTreeAt(repo: string, sha: string): TreeExport {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "se-tree-scan-"));
  const tar = path.join(tmpRoot, "tree.tar");
  const scanRoot = path.join(tmpRoot, "tree");
  fs.mkdirSync(scanRoot);
  try {
    execFileSync("git", ["-C", repo, "archive", "--format=tar", "-o", tar, sha], { stdio: "pipe" });
    execFileSync("tar", ["-x", "-f", tar, "-C", scanRoot], { stdio: "pipe" });
  } catch (e) {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
    throw e;
  }
  fs.rmSync(tar, { force: true });
  return { tmpRoot, scanRoot };
}

export function gitHead(repo: string): string {
  return execFileSync("git", ["-C", repo, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
}

// --redact: gitleaks otherwise echoes the raw secret into its report, which the
// callers persist to run summaries and report files — redact so a detected
// secret is never copied into a durable store. Every caller passes it. It does
// not weaken the baseline: fingerprints are path/rule/line, so a redacted
// capture still matches a redacted rescan (verified on gitleaks 8.30.1).
function runGitleaks(args: string[], opts: { bin?: string; timeoutMs?: number; cwd?: string }): SecretScanResult {
  const bin = opts.bin ?? "gitleaks";
  const res = spawnSync(bin, args, { cwd: opts.cwd, encoding: "utf8", timeout: opts.timeoutMs ?? 2 * 60_000 });
  const output = `${res.stdout ?? ""}${res.stderr ?? ""}`;
  if (res.error || res.status === null) {
    return { state: "error", details: `${res.error ? String(res.error) : "scanner terminated (timeout or signal)"}` };
  }
  if (res.status === 0) return { state: "clean", details: output.trim() };
  if (res.status === 2) return { state: "found", details: output.trim() };
  return { state: "error", details: `gitleaks exited with unexpected code ${res.status}: ${output.trim()}` };
}
