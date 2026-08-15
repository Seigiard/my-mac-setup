// Target-repo mechanics for pipeline runs: run worktree staging, repo run-lock,
// branch naming, orphan sweep. Extracted from the review donors'
// snapshot/cleanup pattern (se-code-review.tsx) and extended for named run
// branches — donors keep their own copies, behavior there is unchanged.
//
// Run state (smithers ps / smithers.db) is injected via GetRunState so lock
// staleness and sweep decisions never depend on pid liveness: an Approval
// pause has no live process but still owns its lock and worktree.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { planContentHash } from "./gates.ts";

const RUN_BRANCH_PREFIX = "se/";
const RUN_ID_TAIL_LENGTH = 8;
const SLUG_MAX_LENGTH = 40;
const LOCK_FILE_NAME = "se-run.lock";

export type RunState = "running" | "waiting-approval" | "interrupted-resumable" | "terminal";

// Returns the run's state, or undefined when the state store has no record of
// it. Every non-terminal run is present in the store, so undefined is treated
// like terminal (reapable/sweepable). Must resolve both full runIds (lock
// holders) and 8-char alphanumeric runId TAILS (parsed from run branch names —
// see runIdTail).
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

// The 8-char run marker is the TAIL of the alphanumeric runId, not its head:
// detached runs are named "run-<epoch-ms>", so their heads are all identical
// and only the tail is unique. UUID tails are equally unique.
export function runIdTail(runId: string): string {
  return runId.toLowerCase().replace(/[^a-z0-9]/g, "").slice(-RUN_ID_TAIL_LENGTH);
}

export function runBranchName(slug: string, runId: string): string {
  return `${RUN_BRANCH_PREFIX}${slugify(slug)}-${runIdTail(runId)}`;
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
  // `git worktree add` never populates submodules, so a repo whose tests load
  // submodule content (this one: tests/helpers/bats-libs) fails validate-cmd in
  // the staged worktree for an environment reason, not a code defect — the work
  // gate then parks the run on a false negative. Failing here is deliberate:
  // staging surfaces the cause immediately instead of an agent leg burning an
  // hour and the gate reporting a missing file.
  if (fs.existsSync(path.join(repo, ".gitmodules"))) {
    try {
      git(worktreePath, "submodule", "update", "--init", "--recursive");
    } catch (err) {
      throw new Error(
        `Submodule init failed in the staged worktree ${worktreePath}: ${errorMessage(err)}`,
      );
    }
  }
  return { worktreePath, branch, baseSha };
}

// Freezes the plan for one run and returns the copy's absolute path — the ONLY
// plan path the work agent is ever given (run-1786717826270: handed the
// launcher's absolute path, the agent resolved every repository path against
// the plan's own repo and wrote its work into the operator's main checkout on
// main, leaving the run branch empty at base).
//
// The copy lands BESIDE the worktree, never inside it: the work gate's
// commitWorkGuarded runs `git add -A`, so a copy inside would be committed to
// the run branch AND would make treeHash(worktree) !== baseTree even when the
// agent did nothing — destroying the KTD14 proof-of-work invariant that is the
// only thing that caught this bug.
//
// The plan on disk is re-hashed against gate 0's hash (KTD7) before anything is
// written: staging a copy of a plan that has already been edited would freeze
// the wrong spec silently. Re-staging on resume is idempotent — an identical
// copy is left alone, a divergent one is overwritten from the launcher's
// current (hash-verified) content. Read-only is intent, not enforcement: no
// chmod, so an operator can still inspect and delete it normally.
export function stageRunPlan(
  planPath: string,
  branch: string,
  expectedPlanHash: string,
  opts?: { worktreeBaseDir?: string },
): string {
  let markdown: string;
  try {
    markdown = fs.readFileSync(planPath, "utf8");
  } catch (err) {
    throw new Error(`Cannot stage the run plan: unreadable plan at ${planPath} (${errorMessage(err)}).`);
  }
  const actualHash = planContentHash(markdown);
  if (actualHash !== expectedPlanHash) {
    throw new Error(
      `Plan content changed since gate 0: ${planPath} hashes to ${actualHash.slice(0, 12)}, expected ${expectedPlanHash.slice(0, 12)} — refusing to freeze a copy of a spec the run never gated (KTD7).`,
    );
  }

  const baseDir = opts?.worktreeBaseDir ?? path.join(os.tmpdir(), "se-pipeline");
  const planDir = path.join(baseDir, `${branch.replace(/\//g, "-")}-plan`);
  fs.mkdirSync(planDir, { recursive: true });
  // Keep the original basename: ce-work and the plan's own body may refer to
  // the plan by file name.
  const copyPath = path.join(planDir, path.basename(planPath));
  const existing = fs.existsSync(copyPath) ? fs.readFileSync(copyPath, "utf8") : undefined;
  if (existing !== markdown) fs.writeFileSync(copyPath, markdown);
  return copyPath;
}

// Digest of the target repo's dirty state, recorded at staging and re-read at
// the work gate to tell whether the main checkout moved while the agent ran
// (see mainCheckoutEscapeReason). A digest, not the porcelain text: it goes
// into a persisted output row, and a big repo's status is kilobytes.
export function repoDirtyDigest(repo: string): string {
  return createHash("sha256").update(git(repo, "status", "--porcelain")).digest("hex");
}

// The frozen plan copy is a sibling of the worktree by construction
// (stageRunPlan), so every cleanup path can find it from the worktree path
// alone — no extra plumbing through the persisted rows. It holds the plan's
// full text outside any repository, so it is removed with the worktree rather
// than left in /tmp for the OS to collect whenever it feels like it.
function removeRunPlanDir(worktreePath: string, log: (message: string) => void): void {
  try {
    fs.rmSync(`${worktreePath}-plan`, { recursive: true, force: true });
  } catch (err) {
    log(`removeRunPlanDir: failed to remove ${worktreePath}-plan: ${errorMessage(err)}`);
  }
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
      removeRunPlanDir(entry.path, log);
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
  // Outside the try: the plan copy must go even when the worktree removal
  // failed, and it is not a git object, so `worktree remove` never touches it.
  removeRunPlanDir(worktreePath, log);
}

// Deterministic guarded commit for the work stage (KTD5): commit the worktree
// only when it is dirty, so a resume that re-runs this step finds a clean tree
// and commits nothing — no duplicate commit. Commits belong to the pipeline,
// never the agent, which keeps them idempotent across crash-resume. Returns
// whether a commit was actually made.
export function commitWorkGuarded(worktreePath: string, message: string): boolean {
  if (git(worktreePath, "status", "--porcelain") === "") return false;
  git(worktreePath, "add", "-A");
  git(worktreePath, "commit", "--no-verify", "-m", message);
  return true;
}

// Snapshot-freeze wrapper around `git stash create`. Raw `stash create` is
// unsafe on a stat-dirty tree (tracked files rewritten byte-identically since
// the last index refresh — e.g. by a validate-cmd run after the gate commit):
// its first change-check reads the stale index and sees "changes", its
// internal refresh then finds none, and it exits 1 printing NOTHING
// (killed run-1786528537862 at the simplify stage). Refresh the index first
// so a stat-dirty tree reads as clean; keep a guard that maps the
// silent-empty exit 1 to "nothing to stash" in case the tree changes between
// the two calls. Returns the stash commit SHA, or "" when there is nothing
// to freeze.
export function stashCreateSafe(worktreePath: string): string {
  try {
    git(worktreePath, "update-index", "-q", "--refresh");
  } catch {
    // non-zero when genuine modifications exist; stash create handles those
  }
  try {
    return git(worktreePath, "stash", "create");
  } catch (err) {
    const e = err as { status?: number | null; stdout?: unknown; stderr?: unknown };
    const silent = e.status === 1 && !String(e.stdout ?? "").trim() && !String(e.stderr ?? "").trim();
    if (silent) return "";
    throw err;
  }
}

// Content hash of a ref's tree object (KTD3/KTD14 proof of work): compares
// CONTENT, not git dirty-state, so proving that the work stage changed anything
// is independent of how or when commits are arranged. `ref` defaults to HEAD.
// True when `sha` is an ancestor of `of` in the repo. Used to scope the
// post-approval rescan diff to the operator's new commits: a rebase/amend
// during the pause breaks ancestry, and the caller falls back fail-closed to
// the full base..HEAD range. Any git error (unknown sha) is "not an ancestor".
export function isAncestor(cwd: string, sha: string, of: string): boolean {
  try {
    execFileSync("git", ["-C", cwd, "merge-base", "--is-ancestor", sha, of], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

export function treeHash(cwd: string, ref = "HEAD"): string {
  return git(cwd, "rev-parse", `${ref}^{tree}`);
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
