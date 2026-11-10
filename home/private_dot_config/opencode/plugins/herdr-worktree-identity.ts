// @ts-nocheck
// OpenCode prompt adapter for herdr-worktree-identity. The engine detaches its
// model worker before this foreground handshake resolves.
import type { Plugin as V2Plugin } from "@opencode/plugin"
import { homedir } from "node:os"
import { join } from "node:path"

let handoffWorktreeIdentity:
  | ((agent: "opencode", sessionID: string, prompt: string, directory: string) => Promise<void>)
  | undefined

try {
  ;({ handoffWorktreeIdentity } = await import(
    join(process.env.HOME || homedir(), ".local", "lib", "agent-hooks", "worktree-identity.ts"),
  ))
} catch {
  handoffWorktreeIdentity = undefined
}

const HerdrWorktreeIdentityV2Plugin = {
  id: "herdr-worktree-identity",
  async setup({ session }) {
    if (!handoffWorktreeIdentity || process.env.HERDR_WORKTREE_IDENTITY_ACTIVE) return

    const registration = await session.hook("prompt", async ({ prompt, sessionID }) => {
      if (prompt.text.trim() === "") return

      try {
        const current = await session.get({ sessionID })

        if (current.parentID) return
        const directory = current.location?.directory

        if (directory) await handoffWorktreeIdentity("opencode", sessionID, prompt.text, directory)
      } catch {
        // OpenCode prompt admission stays available when session lookup fails.
      }
    })

    return async () => {
      await registration.dispose()
    }
  },
} satisfies V2Plugin.Plugin

export default HerdrWorktreeIdentityV2Plugin
