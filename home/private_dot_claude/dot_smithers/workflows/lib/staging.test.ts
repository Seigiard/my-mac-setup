import { afterAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  acquireRepoLock,
  cleanupSnapshot,
  commitWorkGuarded,
  git,
  isAncestor,
  releaseRepoLock,
  runBranchName,
  slugify,
  stageRunWorktree,
  stashCreateSafe,
  sweepOrphans,
  treeHash,
  type GetRunState,
  type RunState,
} from "./staging.ts";

const tempDirs: string[] = [];

function tempDir(prefix: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

function rawGit(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
}

function makeRepo(): string {
  const dir = tempDir("staging-repo-");
  rawGit(dir, "init", "-q", "-b", "main");
  rawGit(dir, "config", "user.email", "test@test.local");
  rawGit(dir, "config", "user.name", "Test");
  fs.writeFileSync(path.join(dir, "file.txt"), "hello\n");
  rawGit(dir, "add", ".");
  rawGit(dir, "commit", "-qm", "init");
  return dir;
}

// A repo carrying a gitlink whose source cannot be fetched. The gitlink is
// written with update-index rather than `submodule add` because git refuses
// local-path submodule transport by default since 2.38, and that refusal is
// exactly what makes this source unfetchable — offline and instant.
function makeRepoWithUnfetchableSubmodule(subDir: string): string {
  const repo = makeRepo();
  fs.writeFileSync(
    path.join(repo, ".gitmodules"),
    `[submodule "${subDir}"]\n\tpath = ${subDir}\n\turl = /nonexistent-submodule-source.git\n`,
  );
  rawGit(repo, "update-index", "--add", "--cacheinfo", `160000,${"0".repeat(39)}1,${subDir}`);
  rawGit(repo, "add", ".gitmodules");
  rawGit(repo, "commit", "-qm", "add submodule gitlink");
  return repo;
}

function fakeRunState(states: Record<string, RunState>): GetRunState {
  return (runId) => {
    for (const [id, state] of Object.entries(states)) {
      if (id === runId || id.startsWith(runId)) return state;
    }
    return undefined;
  };
}

afterAll(() => {
  for (const dir of tempDirs) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe("runBranchName", () => {
  test("is deterministic for the same slug and runId", () => {
    expect(runBranchName("My Plan", "abcd1234efgh")).toBe(runBranchName("My Plan", "abcd1234efgh"));
  });

  test("is unique between two runIds", () => {
    const a = runBranchName("my-plan", "aaaaaaaa-1111");
    const b = runBranchName("my-plan", "bbbbbbbb-2222");
    expect(a).not.toBe(b);
    expect(a).toBe("se/my-plan-aaaa1111");
    expect(b).toBe("se/my-plan-bbbb2222");
  });

  test("is unique between detach-style runIds sharing a long common prefix", () => {
    // #given smithers --detach runIds are "run-<epoch-ms>": only the TAIL varies
    const a = runBranchName("my-plan", "run-1784104646189");
    const b = runBranchName("my-plan", "run-1784104999999");
    // #then
    expect(a).not.toBe(b);
  });
});

describe("slugify", () => {
  test("lowercases and replaces separators with dashes", () => {
    expect(slugify("Feat: Smithers Pipeline!")).toBe("feat-smithers-pipeline");
  });

  test("falls back to 'run' when nothing survives", () => {
    expect(slugify("///***")).toBe("run");
    expect(slugify("")).toBe("run");
  });

  test("caps length", () => {
    expect(slugify("x".repeat(200)).length).toBeLessThanOrEqual(40);
  });
});

describe("stageRunWorktree", () => {
  test("creates a worktree on the named branch, not detached", () => {
    const repo = makeRepo();
    const baseDir = tempDir("staging-wt-");
    const branch = runBranchName("plan", "run11111");
    const baseSha = rawGit(repo, "rev-parse", "HEAD");

    const staged = stageRunWorktree(repo, branch, baseSha, { worktreeBaseDir: baseDir });

    expect(staged.branch).toBe(branch);
    expect(staged.baseSha).toBe(baseSha);
    expect(rawGit(staged.worktreePath, "symbolic-ref", "HEAD")).toBe(`refs/heads/${branch}`);
    expect(rawGit(staged.worktreePath, "rev-parse", "HEAD")).toBe(baseSha);
  });

  test("initializes submodules, which git worktree add leaves empty", () => {
    // #given a repo with a submodule the worktree cannot populate
    const repo = makeRepoWithUnfetchableSubmodule("vendor/lib");
    const baseDir = tempDir("staging-wt-");
    const branch = runBranchName("plan", "run77777");
    const baseSha = rawGit(repo, "rev-parse", "HEAD");

    // #when / #then staging fails loudly at the cause, rather than handing an
    // agent leg a worktree whose submodule-dependent tests cannot run
    expect(() => stageRunWorktree(repo, branch, baseSha, { worktreeBaseDir: baseDir })).toThrow(
      /Submodule init failed/,
    );
  });

  test("skips submodule init for a repo without .gitmodules", () => {
    // #given the common case: no submodules at all
    const repo = makeRepo();
    const baseDir = tempDir("staging-wt-");
    const branch = runBranchName("plan", "run88888");
    const baseSha = rawGit(repo, "rev-parse", "HEAD");

    // #when / #then
    const staged = stageRunWorktree(repo, branch, baseSha, { worktreeBaseDir: baseDir });
    expect(rawGit(staged.worktreePath, "rev-parse", "HEAD")).toBe(baseSha);
  });

  test("a commit made in the worktree is visible on the run branch", () => {
    const repo = makeRepo();
    const baseDir = tempDir("staging-wt-");
    const branch = runBranchName("plan", "run22222");
    const baseSha = rawGit(repo, "rev-parse", "HEAD");
    const staged = stageRunWorktree(repo, branch, baseSha, { worktreeBaseDir: baseDir });

    fs.writeFileSync(path.join(staged.worktreePath, "work.txt"), "work\n");
    rawGit(staged.worktreePath, "add", ".");
    rawGit(staged.worktreePath, "commit", "-qm", "work commit");
    const workSha = rawGit(staged.worktreePath, "rev-parse", "HEAD");

    expect(rawGit(repo, "rev-parse", `refs/heads/${branch}`)).toBe(workSha);
    expect(rawGit(repo, "rev-parse", "main")).toBe(baseSha);
    expect(rawGit(repo, "status", "--porcelain")).toBe("");
  });

  test("refuses when the run branch already exists", () => {
    const repo = makeRepo();
    const baseDir = tempDir("staging-wt-");
    const branch = runBranchName("plan", "run33333");
    const baseSha = rawGit(repo, "rev-parse", "HEAD");
    rawGit(repo, "branch", branch);

    expect(() => stageRunWorktree(repo, branch, baseSha, { worktreeBaseDir: baseDir })).toThrow(
      /branch.*already exists/i,
    );
  });

  test("worktree add into an occupied path gives a clear error", () => {
    const repo = makeRepo();
    const baseDir = tempDir("staging-wt-");
    const branch = runBranchName("plan", "run44444");
    const baseSha = rawGit(repo, "rev-parse", "HEAD");
    const occupied = path.join(baseDir, branch.replace(/\//g, "-"));
    fs.mkdirSync(occupied, { recursive: true });
    fs.writeFileSync(path.join(occupied, "squatter.txt"), "x\n");

    expect(() => stageRunWorktree(repo, branch, baseSha, { worktreeBaseDir: baseDir })).toThrow(
      new RegExp(`occupied.*${path.basename(occupied)}`, "i"),
    );
  });
});

describe("acquireRepoLock", () => {
  test("acquires when no lock exists", () => {
    const repo = makeRepo();
    const result = acquireRepoLock(repo, "run-alpha-0001", fakeRunState({}));
    expect(result.acquired).toBe(true);
  });

  test("refuses while a non-terminal run holds the lock", () => {
    const repo = makeRepo();
    const getRunState = fakeRunState({ "run-alpha-0001": "running" });
    expect(acquireRepoLock(repo, "run-alpha-0001", getRunState).acquired).toBe(true);

    const second = acquireRepoLock(repo, "run-beta-0002", getRunState);
    expect(second.acquired).toBe(false);
    if (!second.acquired) {
      expect(second.holderRunId).toBe("run-alpha-0001");
      expect(second.holderState).toBe("running");
    }
  });

  test("does NOT reap a waiting-approval holder (no live pid)", () => {
    const repo = makeRepo();
    const getRunState = fakeRunState({ "run-alpha-0001": "waiting-approval" });
    expect(acquireRepoLock(repo, "run-alpha-0001", getRunState).acquired).toBe(true);

    const second = acquireRepoLock(repo, "run-beta-0002", getRunState);
    expect(second.acquired).toBe(false);
    if (!second.acquired) expect(second.holderState).toBe("waiting-approval");
  });

  test("does NOT reap an interrupted-resumable holder", () => {
    const repo = makeRepo();
    const getRunState = fakeRunState({ "run-alpha-0001": "interrupted-resumable" });
    expect(acquireRepoLock(repo, "run-alpha-0001", getRunState).acquired).toBe(true);
    expect(acquireRepoLock(repo, "run-beta-0002", getRunState).acquired).toBe(false);
  });

  test("reaps a terminal holder's lock", () => {
    const repo = makeRepo();
    expect(
      acquireRepoLock(repo, "run-alpha-0001", fakeRunState({ "run-alpha-0001": "running" })).acquired,
    ).toBe(true);

    const after = acquireRepoLock(repo, "run-beta-0002", fakeRunState({ "run-alpha-0001": "terminal" }));
    expect(after.acquired).toBe(true);
  });

  test("release lets the next run acquire", () => {
    const repo = makeRepo();
    const getRunState = fakeRunState({ "run-alpha-0001": "running", "run-beta-0002": "running" });
    expect(acquireRepoLock(repo, "run-alpha-0001", getRunState).acquired).toBe(true);
    releaseRepoLock(repo, "run-alpha-0001");
    expect(acquireRepoLock(repo, "run-beta-0002", getRunState).acquired).toBe(true);
  });

  test("release by a non-holder does not drop the lock", () => {
    const repo = makeRepo();
    const getRunState = fakeRunState({ "run-alpha-0001": "running" });
    expect(acquireRepoLock(repo, "run-alpha-0001", getRunState).acquired).toBe(true);
    releaseRepoLock(repo, "run-zzzz-9999");
    expect(acquireRepoLock(repo, "run-beta-0002", getRunState).acquired).toBe(false);
  });
});

describe("sweepOrphans", () => {
  test("removes terminal run worktrees, keeps non-terminal ones", () => {
    const repo = makeRepo();
    const baseDir = tempDir("staging-wt-");
    const baseSha = rawGit(repo, "rev-parse", "HEAD");

    const live = stageRunWorktree(repo, runBranchName("plan", "aaaaaaaa"), baseSha, {
      worktreeBaseDir: baseDir,
    });
    const dead = stageRunWorktree(repo, runBranchName("plan", "bbbbbbbb"), baseSha, {
      worktreeBaseDir: baseDir,
    });

    const removed = sweepOrphans(
      repo,
      fakeRunState({ aaaaaaaa: "waiting-approval", bbbbbbbb: "terminal" }),
      () => {},
    );

    const expectedDeadPath = path.join(fs.realpathSync(baseDir), path.basename(dead.worktreePath));
    expect(removed).toEqual([expectedDeadPath]);
    expect(fs.existsSync(live.worktreePath)).toBe(true);
    expect(fs.existsSync(dead.worktreePath)).toBe(false);
    const list = rawGit(repo, "worktree", "list", "--porcelain");
    expect(list).toContain(live.worktreePath);
    expect(list).not.toContain(dead.worktreePath);
  });

  test("never touches the main working copy or non-run worktrees", () => {
    const repo = makeRepo();
    const baseDir = tempDir("staging-wt-");
    const detached = path.join(baseDir, "detached-snapshot");
    rawGit(repo, "worktree", "add", "--detach", detached, "HEAD");

    const removed = sweepOrphans(repo, fakeRunState({}), () => {});

    expect(removed).toEqual([]);
    expect(fs.existsSync(path.join(repo, "file.txt"))).toBe(true);
    expect(fs.existsSync(detached)).toBe(true);
  });
});

describe("cleanupSnapshot", () => {
  test("removes the worktree and logs nothing on success", () => {
    const repo = makeRepo();
    const baseDir = tempDir("staging-wt-");
    const baseSha = rawGit(repo, "rev-parse", "HEAD");
    const staged = stageRunWorktree(repo, runBranchName("plan", "cccccccc"), baseSha, {
      worktreeBaseDir: baseDir,
    });

    const logs: string[] = [];
    cleanupSnapshot(repo, staged.worktreePath, (msg) => logs.push(msg));

    expect(fs.existsSync(staged.worktreePath)).toBe(false);
    expect(logs).toEqual([]);
  });

  test("logs instead of silently swallowing when removal fails", () => {
    const repo = makeRepo();
    const logs: string[] = [];
    cleanupSnapshot(repo, path.join(os.tmpdir(), "no-such-worktree-xyz"), (msg) => logs.push(msg));
    expect(logs.length).toBeGreaterThan(0);
    expect(logs[0]).toContain("no-such-worktree-xyz");
  });
});

describe("treeHash (KTD3/KTD14 proof of work)", () => {
  test("differs from base after a committed change, matches when content is unchanged", () => {
    // #given a repo staged on a run branch
    const repo = makeRepo();
    const baseDir = tempDir("staging-wt-");
    const baseSha = rawGit(repo, "rev-parse", "HEAD");
    const staged = stageRunWorktree(repo, runBranchName("plan", "tree0001"), baseSha, { worktreeBaseDir: baseDir });
    const baseTree = treeHash(repo, baseSha);

    // #then an unchanged worktree has the base tree hash
    expect(treeHash(staged.worktreePath)).toBe(baseTree);

    // #when real work is committed
    fs.writeFileSync(path.join(staged.worktreePath, "new.txt"), "content\n");
    commitWorkGuarded(staged.worktreePath, "work");

    // #then the head tree hash diverges from base — content changed
    expect(treeHash(staged.worktreePath)).not.toBe(baseTree);
  });
});

describe("commitWorkGuarded (KTD5 idempotent commit)", () => {
  test("commits a dirty tree once and returns true", () => {
    const repo = makeRepo();
    const baseDir = tempDir("staging-wt-");
    const baseSha = rawGit(repo, "rev-parse", "HEAD");
    const staged = stageRunWorktree(repo, runBranchName("plan", "guard001"), baseSha, { worktreeBaseDir: baseDir });

    fs.writeFileSync(path.join(staged.worktreePath, "impl.txt"), "work\n");
    const committed = commitWorkGuarded(staged.worktreePath, "se-pipeline: work");

    expect(committed).toBe(true);
    expect(rawGit(staged.worktreePath, "status", "--porcelain")).toBe("");
    expect(Number(rawGit(staged.worktreePath, "rev-list", "--count", "HEAD"))).toBe(2);
  });

  test("is a no-op on a clean tree — a resume re-run adds NO duplicate commit (KTD5)", () => {
    // #given the work stage already committed once (first gate run)
    const repo = makeRepo();
    const baseDir = tempDir("staging-wt-");
    const baseSha = rawGit(repo, "rev-parse", "HEAD");
    const staged = stageRunWorktree(repo, runBranchName("plan", "guard002"), baseSha, { worktreeBaseDir: baseDir });
    fs.writeFileSync(path.join(staged.worktreePath, "impl.txt"), "work\n");
    expect(commitWorkGuarded(staged.worktreePath, "se-pipeline: work")).toBe(true);
    const shaAfterFirst = rawGit(staged.worktreePath, "rev-parse", "HEAD");
    const countAfterFirst = Number(rawGit(staged.worktreePath, "rev-list", "--count", "HEAD"));

    // #when a crash-resume re-runs the same guarded commit task (kill after
    // commit, before the frame persisted)
    const committedAgain = commitWorkGuarded(staged.worktreePath, "se-pipeline: work");

    // #then nothing is committed: same HEAD, same commit count — no dup (KTD5)
    expect(committedAgain).toBe(false);
    expect(rawGit(staged.worktreePath, "rev-parse", "HEAD")).toBe(shaAfterFirst);
    expect(Number(rawGit(staged.worktreePath, "rev-list", "--count", "HEAD"))).toBe(countAfterFirst);
  });

  test("stages untracked and modified files alike (git add -A)", () => {
    const repo = makeRepo();
    const baseDir = tempDir("staging-wt-");
    const baseSha = rawGit(repo, "rev-parse", "HEAD");
    const staged = stageRunWorktree(repo, runBranchName("plan", "guard003"), baseSha, { worktreeBaseDir: baseDir });

    fs.writeFileSync(path.join(staged.worktreePath, "file.txt"), "modified\n");
    fs.writeFileSync(path.join(staged.worktreePath, "brand-new.txt"), "new\n");
    expect(commitWorkGuarded(staged.worktreePath, "se-pipeline: work")).toBe(true);

    const files = rawGit(staged.worktreePath, "show", "--name-only", "--format=", "HEAD").split("\n").filter(Boolean).sort();
    expect(files).toEqual(["brand-new.txt", "file.txt"]);
  });
});

describe("isAncestor", () => {
  test("прямой предок → true, обратное → false, мусорный SHA → false (fail-closed)", () => {
    // #given репо с двумя коммитами
    const repo = makeRepo();
    const first = git(repo, "rev-parse", "HEAD");
    fs.writeFileSync(path.join(repo, "b.txt"), "b");
    git(repo, "add", "-A");
    git(repo, "commit", "-m", "second");
    const second = git(repo, "rev-parse", "HEAD");

    // #then
    expect(isAncestor(repo, first, second)).toBe(true);
    expect(isAncestor(repo, second, first)).toBe(false);
    expect(isAncestor(repo, "0000000000000000000000000000000000000000", second)).toBe(false);
  });
});

describe("stashCreateSafe (snapshot freeze)", () => {
  // Rewrites a tracked file byte-identically via tmp+rename WITHOUT any
  // interleaving index-refreshing git command (status/diff would write the
  // refreshed index and destroy the condition). The index entry keeps stale
  // stat info while content matches HEAD — the state that made raw
  // `git stash create` exit 1 with empty output and killed a pipeline run's
  // simplify stage.
  function makeStatDirty(repo: string, file: string): void {
    const target = path.join(repo, file);
    const tmp = path.join(repo, `${file}.tmp`);
    fs.writeFileSync(tmp, fs.readFileSync(target));
    fs.renameSync(tmp, target);
  }

  test("clean tree → empty string (nothing to freeze)", () => {
    const repo = makeRepo();
    expect(stashCreateSafe(repo)).toBe("");
  });

  test("genuinely dirty tree → stash SHA, worktree untouched", () => {
    const repo = makeRepo();
    fs.writeFileSync(path.join(repo, "file.txt"), "modified\n");

    const sha = stashCreateSafe(repo);

    expect(sha).toMatch(/^[0-9a-f]{40}$/);
    // #then the snapshot carries the change and the working tree stays dirty
    expect(git(repo, "show", `${sha}:file.txt`)).toBe("modified");
    expect(fs.readFileSync(path.join(repo, "file.txt"), "utf8")).toBe("modified\n");
  });

  test("stat-dirty-only tree (content == HEAD, mtime/inode moved) → empty string, NO throw", () => {
    // #given an index with stale stat info: a file rewritten with identical
    // content right after the commit, no refreshing git command in between
    const repo = makeRepo();
    makeStatDirty(repo, "file.txt");
    // #precondition: non-refreshing plumbing sees a "change" — if this stops
    // holding, the setup no longer reproduces stat-dirtiness and the test
    // would pass vacuously
    expect(git(repo, "diff-index", "HEAD", "--")).toContain("file.txt");

    // #then raw `git stash create` used to exit 1 silently here
    expect(stashCreateSafe(repo)).toBe("");
  });
});
