// Pi prompt adapter for herdr-worktree-identity.
// @ts-nocheck
import { homedir } from "node:os";
import { join } from "node:path";

let handoffWorktreeIdentity: ((agent: "pi", sessionID: string, prompt: string) => Promise<void>) | undefined;

try {
  ({ handoffWorktreeIdentity } = await import(
    join(process.env.HOME || homedir(), ".local", "lib", "agent-hooks", "worktree-identity.ts")
  ));
} catch {
  handoffWorktreeIdentity = undefined;
}

type SessionContext = { sessionManager?: { getSessionId?: () => string | undefined } };

function sessionId(ctx: SessionContext): string | undefined {
  try {
    const id = ctx?.sessionManager?.getSessionId?.();

    return id || undefined;
  } catch {
    return undefined;
  }
}

export default function registerWorktreeIdentity(pi: any): void {
  if (!handoffWorktreeIdentity || process.env.HERDR_ENV !== "1" || process.env.HERDR_WORKTREE_IDENTITY_ACTIVE) return;

  pi.on("before_agent_start", async (event: { prompt?: string }, ctx: SessionContext & { hasUI?: boolean }) => {
    if (ctx?.hasUI !== true) return;
    const id = sessionId(ctx);
    const prompt = event?.prompt ?? "";

    if (!id || prompt.trim() === "") return;
    await handoffWorktreeIdentity("pi", id, prompt);
  });
}
