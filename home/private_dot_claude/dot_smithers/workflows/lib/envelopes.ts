// Work-stage boundary helpers (KTD3/KTD10/KTD13): parse the ce-work
// return-to-caller envelope, run the operator-supplied validate-cmd, and
// secret-scan the run branch diff before anything leaves the machine.
// These perform the external effects; the pure verdicts live in gates.ts.
import { execFileSync, spawnSync } from "node:child_process";
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

export function runValidateCmd(cmd: string, cwd: string, timeoutMs = 10 * 60_000): ValidateCmdResult {
  const res = spawnSync("bash", ["-lc", cmd], { cwd, encoding: "utf8", timeout: timeoutMs });
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

// Scans only the run's own commits (baseSha..HEAD). Exit codes are pinned via
// --exit-code so a scanner crash is never confused with a clean pass: 0 clean,
// 2 leaks, anything else (missing binary, timeout, git errors) = error →
// degraded at the gate (KTD10).
export function secretScanDiff(
  repo: string,
  baseSha: string,
  opts: { bin?: string; timeoutMs?: number } = {},
): SecretScanResult {
  const bin = opts.bin ?? "gitleaks";
  const res = spawnSync(
    bin,
    ["git", "--no-banner", "--exit-code", "2", `--log-opts=${baseSha}..HEAD`, repo],
    { encoding: "utf8", timeout: opts.timeoutMs ?? 2 * 60_000 },
  );
  const output = `${res.stdout ?? ""}${res.stderr ?? ""}`;
  if (res.error || res.status === null) {
    return { state: "error", details: `${res.error ? String(res.error) : "scanner terminated (timeout or signal)"}` };
  }
  if (res.status === 0) return { state: "clean", details: output.trim() };
  if (res.status === 2) return { state: "found", details: output.trim() };
  return { state: "error", details: `gitleaks exited with unexpected code ${res.status}: ${output.trim()}` };
}

export function gitHead(repo: string): string {
  return execFileSync("git", ["-C", repo, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
}
