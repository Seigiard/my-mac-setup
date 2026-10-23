import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export type SetupWorktree = {
  repository: string;
  directory: string;
  marker: string;
};

function git(directory: string, args: string[]): string {
  const result = Bun.spawnSync(["git", ...args], { cwd: directory, stdout: "pipe", stderr: "pipe" });

  if (result.exitCode !== 0) {
    throw new Error(`git ${args.join(" ")} failed: ${result.stderr.toString().trim()}`);
  }

  return result.stdout.toString().trim();
}

export function createSetupWorktree(prefix: string): SetupWorktree {
  const repository = mkdtempSync(join(tmpdir(), prefix));
  const directory = join(repository, "linked");

  git(repository, ["init", "--quiet"]);
  git(repository, ["config", "user.email", "tests@example.com"]);
  git(repository, ["config", "user.name", "Agent hooks tests"]);
  writeFileSync(join(repository, "control.txt"), "control\n");
  git(repository, ["add", "control.txt"]);
  git(repository, ["commit", "--quiet", "-m", "initial"]);
  git(repository, ["worktree", "add", "--quiet", "-b", "setup-status-test", directory]);

  const marker = git(directory, [
    "rev-parse",
    "--path-format=absolute",
    "--git-path",
    "herdr-worktree-setup",
  ]);

  return { repository, directory, marker };
}

export async function createReapedPid(): Promise<number> {
  const child = Bun.spawn(["sh", "-c", "exit 0"]);
  const pid = child.pid;

  if (await child.exited !== 0) throw new Error("test child did not exit cleanly");

  return pid;
}

export function removeSetupWorktree(worktree: SetupWorktree): void {
  rmSync(worktree.repository, { recursive: true, force: true });
}
