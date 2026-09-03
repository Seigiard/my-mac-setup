// Pi prompt adapter for herdr-worktree-identity.
// @ts-nocheck
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";

const ENGINE_NAME = "herdr-worktree-identity";
const HANDSHAKE_TIMEOUT_MS = 1000;

function enginePath(): string {
  if (process.env.HERDR_WORKTREE_IDENTITY_ENGINE) return process.env.HERDR_WORKTREE_IDENTITY_ENGINE;
  const home = process.env.HOME;
  if (home) {
    const local = path.join(home, ".local", "bin", ENGINE_NAME);
    if (existsSync(local)) return local;
  }
  return ENGINE_NAME;
}

function sessionId(ctx: any): string | undefined {
  try {
    const id = ctx?.sessionManager?.getSessionId?.();
    return typeof id === "string" && id.length > 0 ? id : undefined;
  } catch {
    return undefined;
  }
}

function callEngine(args: string[], prompt: string): Promise<void> {
  return new Promise((resolve) => {
    try {
      const child = spawn(enginePath(), args, { stdio: ["pipe", "ignore", "ignore"] });
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

function engineArgs(id: string): string[] {
  const args = ["--agent", "pi", "--session", id];
  if (process.env.HERDR_PANE_ID) args.push("--pane", process.env.HERDR_PANE_ID);
  if (process.env.HERDR_WORKSPACE_ID) args.push("--workspace", process.env.HERDR_WORKSPACE_ID);
  return args;
}

export default function registerWorktreeIdentity(pi: any): void {
  if (process.env.HERDR_ENV !== "1" || process.env.HERDR_WORKTREE_IDENTITY_ACTIVE) return;

  pi.on("before_agent_start", async (event: any, ctx: any) => {
    if (ctx?.hasUI !== true) return;
    const id = sessionId(ctx);
    const prompt = typeof event?.prompt === "string" ? event.prompt : "";
    if (!id || prompt.trim() === "") return;
    await callEngine(engineArgs(id), prompt);
  });
}
