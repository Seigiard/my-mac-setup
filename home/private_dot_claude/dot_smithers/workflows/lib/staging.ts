// Target-repo mechanics for pipeline runs: run worktree staging, repo run-lock,
// branch naming, orphan sweep. Extracted from the review donors'
// snapshot/cleanup pattern (se-code-review.tsx) and extended for named run
// branches — donors keep their own copies, behavior there is unchanged.
//
// Run state (smithers ps / smithers.db) is injected via GetRunState so lock
// staleness and sweep decisions never depend on pid liveness: an Approval
// pause has no live process but still owns its lock and worktree.
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const RUN_BRANCH_PREFIX = "se/";
const RUN_ID_PREFIX_LENGTH = 8;
const SLUG_MAX_LENGTH = 40;
const LOCK_FILE_NAME = "se-run.lock";

export type RunState = "running" | "waiting-approval" | "interrupted-resumable" | "terminal";

// Returns the run's state, or undefined when the state store has no record of
// it. Every non-terminal run is present in the store, so undefined is treated
// like terminal (reapable/sweepable). Must resolve both full runIds (lock
// holders) and 8-char runId prefixes (parsed from run branch names).
export type GetRunState = (runId: string) => RunState | undefined;

export interface StagedWorktree {
  worktreePath: string;
  branch: string;
  baseSha: string;
}

export type LockResult =
  | { acquired: true }
  | { acquired: false; holderRunId: string; holderState: RunState | undefined };

export function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
}

export function slugify(input: string): string {
  const slug = input
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, SLUG_MAX_LENGTH)
    .replace(/-+$/, "");
  return slug || "run";
}

export function runBranchName(slug: string, runId: string): string {
  return `${RUN_BRANCH_PREFIX}${slugify(slug)}-${runId.slice(0, RUN_ID_PREFIX_LENGTH)}`;
}

export function parseRunBranch(branch: string): { slug: string; runId8: string } | undefined {
  const match = branch.match(/^se\/(.+)-([a-z0-9]{8})$/);
  if (!match) return undefined;
  return { slug: match[1], runId8: match[2] };
}

export function detectBaseRef(repo: string): string {
  try {
    const head = git(repo, "symbolic-ref", "refs/remotes/origin/HEAD");
    return head.replace("refs/remotes/", "");
  } catch {
    for (const ref of ["origin/main", "main", "master"]) {
      try {
        git(repo, "rev-parse", "--verify", ref);
        return ref;
      } catch {}
    }
    throw new Error("Cannot detect a base branch (origin/HEAD, origin/main, main, master all missing).");
  }
}

// Creates the run worktree on a NAMED branch (not detached HEAD) so work
// commits land on a ref that verify-code can target, from baseSha — no stash
// snapshot: the pipeline works from HEAD, not the operator's WIP (KTD4).
export function stageRunWorktree(
  repo: string,
  branch: string,
  baseSha: string,
  opts?: { worktreeBaseDir?: string },
): StagedWorktree {
  if (branchExists(repo, branch)) {
    throw new Error(
      `Run branch "${branch}" already exists in ${repo} — refusing to reuse it. Remove it or pick another runId.`,
    );
  }

  const baseDir = opts?.worktreeBaseDir ?? path.join(os.tmpdir(), "se-pipeline");
  const worktreePath = path.join(baseDir, branch.replace(/\//g, "-"));
  if (fs.existsSync(worktreePath) && fs.readdirSync(worktreePath).length > 0) {
    throw new Error(
      `Worktree path is occupied: ${worktreePath} — refusing to stage over existing files. Sweep orphans or remove it manually.`,
    );
  }
  fs.mkdirSync(baseDir, { recursive: true });

  git(repo, "worktree", "add", "-b", branch, worktreePath, baseSha);
  return { worktreePath, branch, baseSha };
}

// Lock staleness is decided by RUN STATE, not pid liveness: all non-terminal
// runs (running, waiting-approval, interrupted-resumable) hold the lock; only
// a terminal (or unknown-to-the-store) run's lock may be reaped.
export function acquireRepoLock(repo: string, runId: string, getRunState: GetRunState): LockResult {
  const lockPath = repoLockPath(repo);
  const payload = JSON.stringify({ runId, acquiredAt: new Date().toISOString() });

  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      fs.writeFileSync(lockPath, payload, { flag: "wx" });
      return { acquired: true };
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
      const holderRunId = readLockHolder(lockPath);
      if (holderRunId === undefined) {
        fs.rmSync(lockPath, { force: true });
        continue;
      }
      const holderState = getRunState(holderRunId);
      if (holderState !== undefined && holderState !== "terminal") {
        return { acquired: false, holderRunId, holderState };
      }
      fs.rmSync(lockPath, { force: true });
    }
  }
  throw new Error(`Could not acquire repo lock at ${lockPath}: lost the race twice.`);
}

export function releaseRepoLock(repo: string, runId: string): void {
  const lockPath = repoLockPath(repo);
  if (readLockHolder(lockPath) === runId) {
    fs.rmSync(lockPath, { force: true });
  }
}

// `git worktree prune` + removal of run worktrees whose runId is TERMINAL (or
// unknown). Non-terminal worktrees — including Approval pauses with no live
// process — are never touched. Callers resuming a run must mark its runId
// live BEFORE sweeping. Run branches are kept: they carry the work commits.
export function sweepOrphans(
  repo: string,
  getRunState: GetRunState,
  log: (message: string) => void = console.error,
): string[] {
  git(repo, "worktree", "prune");

  const removed: string[] = [];
  for (const entry of listLinkedWorktrees(repo)) {
    const parsed = entry.branch ? parseRunBranch(entry.branch) : undefined;
    if (!parsed) continue;
    const state = getRunState(parsed.runId8);
    if (state !== undefined && state !== "terminal") continue;
    try {
      git(repo, "worktree", "remove", "--force", entry.path);
      removed.push(entry.path);
      log(`sweepOrphans: removed worktree ${entry.path} (run ${parsed.runId8}, state ${state ?? "unknown"})`);
    } catch (err) {
      log(`sweepOrphans: failed to remove worktree ${entry.path}: ${errorMessage(err)}`);
    }
  }
  return removed;
}

// Donor's cleanup (se-code-review.tsx:134-142), but failures are logged
// instead of silently swallowed.
export function cleanupSnapshot(
  repo: string,
  worktreePath: string,
  log: (message: string) => void = console.error,
): void {
  try {
    git(repo, "worktree", "remove", "--force", worktreePath);
  } catch (err) {
    log(`cleanupSnapshot: worktree remove failed for ${worktreePath}: ${errorMessage(err)}`);
    try {
      git(repo, "worktree", "prune");
    } catch (pruneErr) {
      log(`cleanupSnapshot: worktree prune failed: ${errorMessage(pruneErr)}`);
    }
  }
}

function branchExists(repo: string, branch: string): boolean {
  try {
    git(repo, "rev-parse", "--verify", "--quiet", `refs/heads/${branch}`);
    return true;
  } catch {
    return false;
  }
}

function repoLockPath(repo: string): string {
  const gitDir = git(repo, "rev-parse", "--absolute-git-dir");
  return path.join(gitDir, LOCK_FILE_NAME);
}

function readLockHolder(lockPath: string): string | undefined {
  try {
    const parsed: unknown = JSON.parse(fs.readFileSync(lockPath, "utf8"));
    const runId = (parsed as { runId?: unknown })?.runId;
    return typeof runId === "string" ? runId : undefined;
  } catch {
    return undefined;
  }
}

interface WorktreeEntry {
  path: string;
  branch: string | undefined;
}

function listLinkedWorktrees(repo: string): WorktreeEntry[] {
  const porcelain = git(repo, "worktree", "list", "--porcelain");
  const entries: WorktreeEntry[] = [];
  let current: WorktreeEntry | undefined;
  for (const line of porcelain.split("\n")) {
    if (line.startsWith("worktree ")) {
      current = { path: line.slice("worktree ".length), branch: undefined };
      entries.push(current);
    } else if (line.startsWith("branch ") && current) {
      current.branch = line.slice("branch ".length).replace(/^refs\/heads\//, "");
    }
  }
  return entries.slice(1);
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
