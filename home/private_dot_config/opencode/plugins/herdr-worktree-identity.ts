// @ts-nocheck
// OpenCode prompt adapter for herdr-worktree-identity. The engine detaches its
// model worker before this foreground handshake resolves.
import type { Plugin } from "@opencode-ai/plugin"
import { homedir } from "node:os"
import { join } from "node:path"

let handoffWorktreeIdentity:
  | ((agent: "opencode", sessionID: string, prompt: string) => Promise<void>)
  | undefined
try {
  ;({ handoffWorktreeIdentity } = await import(
    join(process.env.HOME || homedir(), ".local", "lib", "agent-hooks", "worktree-identity.ts"),
  ))
} catch {
  handoffWorktreeIdentity = undefined
}

export const HerdrWorktreeIdentityPlugin: Plugin = async () => {
  if (!handoffWorktreeIdentity || process.env.HERDR_ENV !== "1" || process.env.HERDR_WORKTREE_IDENTITY_ACTIVE) return {}

  const childSessions = new Set<string>()
  return {
    "chat.message": async (input, output) => {
      const sessionID = input?.sessionID
      if (!sessionID || childSessions.has(sessionID)) return
      const prompt = (Array.isArray(output?.parts) ? output.parts : [])
        .filter((part: any) => part?.type === "text" && typeof part.text === "string")
        .map((part: any) => part.text)
        .join("\n")
      if (prompt.trim() !== "") await handoffWorktreeIdentity("opencode", sessionID, prompt)
    },
    event: async ({ event }) => {
      const type = (event as any)?.type
      const info = (event as any)?.properties?.info
      if (type === "session.deleted" && info?.id) childSessions.delete(info.id)
      else if (info?.id && info.parentID) childSessions.add(info.id)
    },
  }
}
