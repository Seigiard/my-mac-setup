// Pi prompt adapter for herdr-worktree-identity.
// @ts-nocheck
import { join } from "node:path";

let handoffWorktreeIdentity: ((agent: "pi", sessionID: string, prompt: string) => Promise<void>) | undefined;
try {
  ({ handoffWorktreeIdentity } = await import(
    join(process.env.HOME ?? "", ".local", "lib", "agent-hooks", "worktree-identity.ts")
  ));
} catch {
  handoffWorktreeIdentity = undefined;
}

function sessionId(ctx: any): string | undefined {
  try {
    const id = ctx?.sessionManager?.getSessionId?.();
    return typeof id === "string" && id.length > 0 ? id : undefined;
  } catch {
    return undefined;
  }
}

export default function registerWorktreeIdentity(pi: any): void {
  if (!handoffWorktreeIdentity || process.env.HERDR_ENV !== "1" || process.env.HERDR_WORKTREE_IDENTITY_ACTIVE) return;

  pi.on("before_agent_start", async (event: any, ctx: any) => {
    if (ctx?.hasUI !== true) return;
    const id = sessionId(ctx);
    const prompt = typeof event?.prompt === "string" ? event.prompt : "";
    if (!id || prompt.trim() === "") return;
    await handoffWorktreeIdentity("pi", id, prompt);
  });
}
