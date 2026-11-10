// Shared subprocess handoff for the Pi and OpenCode worktree-identity adapters.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

const ENGINE_NAME = "herdr-worktree-identity";

const HANDSHAKE_TIMEOUT_MS = 1000;

export type WorktreeIdentityAgent = "pi" | "opencode";

function enginePath(): string {
  const configured = process.env.HERDR_WORKTREE_IDENTITY_ENGINE;

  if (configured) return configured;
  const home = process.env.HOME;

  if (home) {
    const local = join(home, ".local", "bin", ENGINE_NAME);

    if (existsSync(local)) return local;
  }

  return ENGINE_NAME;
}

export function handoffWorktreeIdentity(
  agent: WorktreeIdentityAgent,
  sessionID: string,
  prompt: string,
  directory: string,
): Promise<void> {
  return new Promise((resolve) => {
    try {
      const child = spawn(enginePath(), ["--agent", agent, "--session", sessionID, "--cwd", directory], { stdio: ["pipe", "ignore", "ignore"] });
      let settled = false;

      const finish = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve();
      };

      const timer = setTimeout(() => {
        child.stdin?.destroy();
        child.kill("SIGTERM");
        finish();
      }, HANDSHAKE_TIMEOUT_MS);

      timer.unref?.();
      child.once("error", finish);
      child.once("close", finish);
      child.stdin?.once("error", () => {});
      child.stdin?.end(prompt);
    } catch {
      resolve();
    }
  });
}
