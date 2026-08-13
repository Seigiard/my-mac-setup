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
import { commitWorkGuarded, git, treeHash, type StagedWorktree } from "./staging.ts";

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
  validateTimeoutMs?: number;
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

function secretScanEffect(input: unknown, ctx: ComputeEffectContext): SecretScanResult {
  const base = (input as { baseShaRef?: string | null })?.baseShaRef ?? ctx.baseSha;
  return secretScanDiff(ctx.worktreePath, base, { bin: ctx.gitleaksBin, timeoutMs: ctx.scanTimeoutMs });
}

// KTD3: a rescan only re-runs when the operator moved HEAD during an approval
// pause. An unmoved HEAD is a deterministic no-op green (rescanGate treats
// moved:false as clean). When moved, the scan and — if a validate-cmd is in
// context — the validate exit code are recorded so the gate can fail-close on
// leaks or a broken validate.
function rescanEffect(input: unknown, ctx: ComputeEffectContext): {
  moved: boolean;
  currentHead?: string;
  scanBase?: string;
  scan?: SecretScanResult;
  validateExitCode?: number | null;
} {
  const scanBase = (input as { scanBaseRef?: string | null })?.scanBaseRef ?? ctx.baseSha;
  const currentHead = gitHead(ctx.worktreePath);
  if (currentHead === scanBase) {
    return { moved: false, currentHead, scanBase };
  }
  const scan = secretScanDiff(ctx.worktreePath, scanBase, { bin: ctx.gitleaksBin, timeoutMs: ctx.scanTimeoutMs });
  const validateCmd = (input as { validateCmd?: string })?.validateCmd;
  const validateExitCode = typeof validateCmd === "string"
    ? runValidateCmd(validateCmd, ctx.worktreePath, ctx.validateTimeoutMs).exitCode
    : null;
  return { moved: true, currentHead, scanBase, scan, validateExitCode };
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
// exit code. A `{ref}` form is an unresolved operator-source reference this
// headless path cannot dereference, so it records exitCode:null — the gateFn
// then fails closed rather than treating an unrun command as a pass.
function runValidateEffect(input: unknown, ctx: ComputeEffectContext): { exitCode: number | null; output: string } {
  const cmd = (input as { validateCmd?: string | { ref: string } })?.validateCmd;
  if (typeof cmd !== "string") {
    return { exitCode: null, output: "validate-cmd is an unresolved reference; not executed (KTD15)" };
  }
  return runValidateCmd(cmd, ctx.worktreePath, ctx.validateTimeoutMs);
}

// R11/KTD10: collect named outputs into the artifact manifest the outcome record
// consumes. Only files that actually exist in the worktree enter the manifest;
// a requested name with no file is dropped, so a downstream reader never
// resolves a manifest entry to a missing path.
function proofArtifactsEffect(input: unknown, ctx: ComputeEffectContext): { manifest: { name: string; path: string }[] } {
  const names = (input as { names?: string[] })?.names ?? [];
  const manifest = names
    .map((name) => ({ name, path: path.resolve(ctx.worktreePath, name) }))
    .filter((entry) => fs.existsSync(entry.path));
  return { manifest };
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

function defaultGh(args: string[], cwd: string): { status: number | null; stdout: string; stderr: string } {
  const res = spawnSync("gh", args, { cwd, encoding: "utf8" });
  return { status: res.status, stdout: res.stdout ?? "", stderr: res.stderr ?? "" };
}

// KTD11 pre-push guard: only ever push the run-id branch, to its own ref. A
// caller cannot redirect this to an arbitrary ref.
function defaultPush(branch: string, cwd: string): { ok: boolean; stderr: string } {
  try {
    git(cwd, "push", "origin", `HEAD:refs/heads/${branch}`);
    return { ok: true, stderr: "" };
  } catch (e) {
    return { ok: false, stderr: e instanceof Error ? e.message : String(e) };
  }
}

function extractUrl(text: string): string | null {
  const match = text.match(/https?:\/\/\S+/);
  return match ? match[0] : null;
}
