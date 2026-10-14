// Shared subprocess handoff for the Pi and OpenCode worktree-identity adapters.

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";

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

function engineArgs(agent: WorktreeIdentityAgent, sessionID: string): string[] {
  const args = ["--agent", agent, "--session", sessionID];

  if (process.env.HERDR_PANE_ID) args.push("--pane", process.env.HERDR_PANE_ID);

  if (process.env.HERDR_WORKSPACE_ID) args.push("--workspace", process.env.HERDR_WORKSPACE_ID);

  return args;
}

// The engine falls back to the pane's process cwd, which stays at the launch
// directory when a session moves to another checkout. Write the record the
// Claude statusline writes: one absolute path under agent-cwd/, keyed by the
// session id in base64url without padding (encode_key in
// herdr-worktree-state.sh), renamed into place so a reader never sees half.
export function recordSessionDirectory(sessionID: string, directory: string): void {
  if (!sessionID || !isAbsolute(directory)) return;

  try {
    const root = join(
      process.env.HERDR_WORKTREE_IDENTITY_STATE_DIR || join(process.env.HOME || homedir(), ".cache", "herdr-worktree-identity"),
      "agent-cwd",
    );

    const key = Buffer.from(sessionID).toString("base64url");
    const tmp = join(root, `.${key}.${process.pid}`);

    mkdirSync(root, { recursive: true });

    try {
      writeFileSync(tmp, `${directory}\n`);
      renameSync(tmp, join(root, key));
    } finally {
      rmSync(tmp, { force: true });
    }
  } catch {
    // The record only sharpens the engine's checkout choice; never block a prompt on it.
  }
}

export function handoffWorktreeIdentity(
  agent: WorktreeIdentityAgent,
  sessionID: string,
  prompt: string,
): Promise<void> {
  return new Promise((resolve) => {
    try {
      const child = spawn(enginePath(), engineArgs(agent, sessionID), { stdio: ["pipe", "ignore", "ignore"] });
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
