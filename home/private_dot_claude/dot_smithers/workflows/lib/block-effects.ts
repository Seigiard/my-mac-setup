// Compute-block effect bodies (U3/U9/KTD4). These are the effectful steps the
// interpreter runs for `kind: compute` blocks — the real work behind the pure
// gateFn classifications in blocks/index.ts. Kept out of se-flow.tsx so they are
// unit-testable against a fixture worktree without a Smithers runtime, and so the
// interpreter's statically-imported module graph reason (KTD1) is isolated from
// effect edits. Each effect returns the exact recorded shape its block's gateFn
// classifies; secret-scan, commit, and validate reuse the single lib
// implementation the fixed pipeline also uses (R3).
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";

import { gitHead, runValidateCmd, secretScanDiff, type SecretScanResult } from "./envelopes.ts";
import { commitWorkGuarded, treeHash, type StagedWorktree } from "./staging.ts";

export type GhRunner = (args: string[], cwd: string) => { status: number | null; stdout: string; stderr: string };
export type PushRunner = (branch: string, cwd: string) => { ok: boolean; stderr: string };

export interface ComputeEffectContext extends Partial<StagedWorktree> {
  worktreePath: string;
  baseSha: string;
  branch: string;
  runId: string;
  commitMessage?: string;
  prBody?: string;
  gitleaksBin?: string;
  scanTimeoutMs?: number;
  // The behavior check, supplied by the operator at launch. It never arrives in
  // block input: a spec that could name the command would choose what "verified"
  // means for its own run (KTD15).
  validateCmd?: string;
  validateTimeoutMs?: number;
  // HEAD as it stood when the run parked. The rescan block compares against it
  // to tell operator commits from the run's own. Absent means "unknown", which
  // rescans rather than assuming nothing changed.
  pauseHead?: string;
  gh?: GhRunner;
  push?: PushRunner;
}

type ComputeEffect = (input: unknown, ctx: ComputeEffectContext) => unknown;

// One entry per compute block name (lib/blocks/index.ts is the source of
// truth for those names; block-effects.test.ts cross-checks this map against
// the registry so a renamed or added compute block is a loud test failure,
// never a silent drift between the two lists).
const COMPUTE_EFFECTS: Record<string, ComputeEffect> = {
  "secret-scan": secretScanEffect,
  rescan: rescanEffect,
  "commit-work": (_input, ctx) => commitWorkEffect(ctx),
  "run-validate": runValidateEffect,
  "proof-artifacts": proofArtifactsEffect,
  pr: prEffect,
};

export const COMPUTE_EFFECT_NAMES: string[] = Object.keys(COMPUTE_EFFECTS);

// Dispatch a compute block to its effect. Unknown names throw so a registry
// entry without an effect body is a loud failure, never a silent `{}` that a
// gateFn would then misclassify.
export function runComputeEffect(name: string, input: unknown, ctx: ComputeEffectContext): unknown {
  const effect = COMPUTE_EFFECTS[name];
  if (!effect) {
    throw new Error(`no compute effect registered for block "${name}"`);
  }
  return effect(input, ctx);
}

// The scan base is the staged worktree's own base, never a spec field. A
// composer-supplied base could name the current HEAD, leave gitleaks an empty
// commit range, and turn "nothing scanned" into a green gate — which defeats
// the one control KTD13 rests on. For the same reason an empty range is an
// error state here, not clean: a scan that examined no commits has proved
// nothing, and the gateFn fails closed on anything that is not "clean".
function secretScanEffect(_input: unknown, ctx: ComputeEffectContext): SecretScanResult {
  if (gitHead(ctx.worktreePath) === ctx.baseSha) {
    return {
      state: "error",
      details: `scan range ${ctx.baseSha}..HEAD is empty — no commits to scan, which is not a clean result (KTD13)`,
    };
  }
  return secretScanDiff(ctx.worktreePath, ctx.baseSha, { bin: ctx.gitleaksBin, timeoutMs: ctx.scanTimeoutMs });
}

// A rescan covers commits an operator added while the run was parked. It
// compares HEAD against the head recorded at pause time, not against the staged
// base — the base is always behind by the run's own commits, so a base
// comparison reported "moved" on every rescan and the no-op path was dead code.
// An unknown pause head rescans rather than reporting a no-op: the cheap scan is
// the safe answer when the interpreter cannot say what changed.
function rescanEffect(_input: unknown, ctx: ComputeEffectContext): {
  moved: boolean;
  currentHead?: string;
  scanBase?: string;
  scan?: SecretScanResult;
  validateExitCode?: number | null;
} {
  const currentHead = gitHead(ctx.worktreePath);
  if (ctx.pauseHead !== undefined && currentHead === ctx.pauseHead) {
    return { moved: false, currentHead, scanBase: ctx.pauseHead };
  }
  const scan = secretScanDiff(ctx.worktreePath, ctx.baseSha, { bin: ctx.gitleaksBin, timeoutMs: ctx.scanTimeoutMs });
  const validateCmd = (ctx.validateCmd ?? "").trim();
  const validateExitCode = validateCmd === "" ? null : runValidateCmd(validateCmd, ctx.worktreePath, ctx.validateTimeoutMs).exitCode;
  return { moved: true, currentHead, scanBase: ctx.baseSha, scan, validateExitCode };
}

// KTD4/KTD5: the work agent leaves changes uncommitted; the compute block
// commits them exactly once (guarded no-op on a clean tree). Tree hashes prove
// content changed — a headTree equal to baseTree is the "no real change" red the
// gateFn catches, not a self-report.
function commitWorkEffect(ctx: ComputeEffectContext): { baseTree: string; headTree: string; committed: boolean } {
  const baseTree = treeHash(ctx.worktreePath, ctx.baseSha);
  const committed = commitWorkGuarded(ctx.worktreePath, ctx.commitMessage ?? `se-flow: work on ${ctx.branch}`);
  const headTree = treeHash(ctx.worktreePath);
  return { baseTree, headTree, committed };
}

// KTD3/KTD15: run the operator-sourced validate-cmd and record its ground-truth
// exit code. A run launched without one records exitCode:null — the gateFn then
// fails closed rather than treating an unrun command as a pass.
function runValidateEffect(_input: unknown, ctx: ComputeEffectContext): { exitCode: number | null; output: string } {
  const cmd = (ctx.validateCmd ?? "").trim();
  if (cmd === "") {
    return { exitCode: null, output: "no operator-supplied validate-cmd for this run; not executed (KTD15)" };
  }
  return runValidateCmd(cmd, ctx.worktreePath, ctx.validateTimeoutMs);
}

// R11/KTD10: collect named outputs into the artifact manifest the outcome record
// consumes. Only files that actually exist in the worktree enter the manifest;
// a requested name with no file is dropped, so a downstream reader never
// resolves a manifest entry to a missing path.
//
// Artifact names come from the spec, so they are composer-controlled: "../.ssh/id_rsa"
// or a symlink planted in the worktree would otherwise resolve outside the
// worktree and get copied into the durable run archive. Every entry is confined
// to the worktree after symlink resolution, and an escaping name is dropped.
function proofArtifactsEffect(input: unknown, ctx: ComputeEffectContext): { manifest: { name: string; path: string }[] } {
  const names = (input as { names?: string[] })?.names ?? [];
  const root = fs.realpathSync(ctx.worktreePath);
  const manifest = names
    .map((name) => ({ name, path: path.resolve(ctx.worktreePath, name) }))
    .filter((entry) => fs.existsSync(entry.path))
    .filter((entry) => isInside(root, fs.realpathSync(entry.path)));
  return { manifest };
}

function isInside(root: string, candidate: string): boolean {
  const rel = path.relative(root, candidate);
  return rel !== "" && !rel.startsWith("..") && !path.isAbsolute(rel);
}

// R11/KTD11/KTD13: push the run-id branch through the pre-push guard and open a
// PR embedding the secret-scanned body. Every failure mode is classified, never
// silent: unauthenticated gh, a rejected push, and an already-open PR each map
// to a distinct result the gateFn reads.
function prEffect(input: unknown, ctx: ComputeEffectContext): { result: "opened" | "exists" | "unauthenticated" | "push-rejected"; url: string | null } {
  const gh = ctx.gh ?? defaultGh;
  const title = (input as { title?: string })?.title ?? `se-flow run ${ctx.runId}`;
  const draft = (input as { draft?: boolean })?.draft ?? false;

  if (gh(["auth", "status"], ctx.worktreePath).status !== 0) {
    return { result: "unauthenticated", url: null };
  }

  const pushed = (ctx.push ?? defaultPush)(ctx.branch, ctx.worktreePath);
  if (!pushed.ok) {
    return { result: "push-rejected", url: null };
  }

  const existing = gh(["pr", "view", ctx.branch, "--json", "url", "-q", ".url"], ctx.worktreePath);
  if (existing.status === 0 && existing.stdout.trim()) {
    return { result: "exists", url: existing.stdout.trim() };
  }

  const args = ["pr", "create", "--title", title, "--body", ctx.prBody ?? `se-flow run ${ctx.runId}`, "--head", ctx.branch];
  if (draft) args.push("--draft");
  const created = gh(args, ctx.worktreePath);
  if (created.status === 0) {
    return { result: "opened", url: created.stdout.trim() || null };
  }
  if (/already exists/i.test(created.stderr)) {
    return { result: "exists", url: extractUrl(created.stderr) };
  }
  if (/auth|login|gh auth/i.test(created.stderr)) {
    return { result: "unauthenticated", url: null };
  }
  return { result: "push-rejected", url: null };
}

// Both network calls carry a hang guard. Without one a stalled gh or a push
// waiting on credentials holds the block until the whole run's timeout, with no
// recorded result. A timeout surfaces as a non-zero status the gateFn reds.
const NETWORK_TIMEOUT_MS = 5 * 60_000;

function defaultGh(args: string[], cwd: string): { status: number | null; stdout: string; stderr: string } {
  const res = spawnSync("gh", args, { cwd, encoding: "utf8", timeout: NETWORK_TIMEOUT_MS });
  if (res.error) {
    return { status: null, stdout: res.stdout ?? "", stderr: `gh did not complete: ${res.error.message}` };
  }
  return { status: res.status, stdout: res.stdout ?? "", stderr: res.stderr ?? "" };
}

// KTD11 pre-push guard: only ever push the run-id branch, to its own ref. A
// caller cannot redirect this to an arbitrary ref.
function defaultPush(branch: string, cwd: string): { ok: boolean; stderr: string } {
  const res = spawnSync("git", ["-C", cwd, "push", "origin", `HEAD:refs/heads/${branch}`], {
    encoding: "utf8",
    timeout: NETWORK_TIMEOUT_MS,
  });
  if (res.error) return { ok: false, stderr: `push did not complete: ${res.error.message}` };
  return res.status === 0 ? { ok: true, stderr: "" } : { ok: false, stderr: res.stderr ?? "" };
}

function extractUrl(text: string): string | null {
  const match = text.match(/https?:\/\/\S+/);
  return match ? match[0] : null;
}
