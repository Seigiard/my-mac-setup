// pi adapter for herdr-task-sync.
//
// Sits beside herdr's own ~/.pi/agent/extensions/herdr-agent-state.ts, which is
// herdr-managed and must never be edited: its header says to add custom hooks
// beside it instead.
//
// Two events feed the shared naming engine:
//   session_start        seed the pane's task from the pi session name, when
//                        the session has one (a /name'd or resumed session)
//   before_agent_start   name the session from the submitted prompt
//
// The engine returns after its bounded atomic inbox commit. Model and
// presentation work stays detached inside the engine.
// @ts-nocheck

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";

const ENGINE_NAME = "herdr-task-sync";

function enginePath(): string {
  const home = process.env.HOME;
  if (home) {
    const local = path.join(home, ".local", "bin", ENGINE_NAME);
    if (existsSync(local)) return local;
  }
  return ENGINE_NAME;
}

function enabled(): boolean {
  // HERDR_TASK_SYNC_ACTIVE marks a one-shot pi run started by the engine
  // itself; naming must not name its own naming call.
  return process.env.HERDR_ENV === "1" && !process.env.HERDR_TASK_SYNC_ACTIVE;
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
      const child = spawn(enginePath(), args, {
        stdio: ["pipe", "ignore", "ignore"],
      });
      let settled = false;
      const ignoreStdinError = () => {};
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
      }, 1000);
      timer.unref?.();
      child.once("error", finish);
      child.once("close", finish);
      child.stdin?.once("error", ignoreStdinError);
      child.stdin?.end(prompt);
    } catch {
      // Naming is best-effort: a missing engine must never break a pi session.
      resolve();
    }
  });
}

export default function (pi) {
  if (!enabled()) return;

  // Only a session with a UI owns the pane. Headless one-shot runs (`pi -p`,
  // including the naming call itself) start without one and must not rename
  // the pane. herdr's own extension gates on the same flag.
  let rootSession = false;

  pi.on("session_start", async (_event, ctx) => {
    if (ctx?.hasUI !== true) return;
    rootSession = true;
    const id = sessionId(ctx);
    if (!id) return;
    let name: string | undefined;
    try {
      name = pi.getSessionName?.();
    } catch {
      name = undefined;
    }
    if (typeof name !== "string" || name.trim() === "") return;
    await callEngine(["--agent", "pi", "--session", id, "--set", name], "");
  });

  pi.on("before_agent_start", async (event, ctx) => {
    if (!rootSession) return;
    const id = sessionId(ctx);
    if (!id) return;
    const prompt = typeof event?.prompt === "string" ? event.prompt : "";
    if (prompt.trim() === "") return;
    await callEngine(["--agent", "pi", "--session", id], prompt);
  });
}
