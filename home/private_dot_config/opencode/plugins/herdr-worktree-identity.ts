// @ts-nocheck
// OpenCode prompt adapter for herdr-worktree-identity. The engine detaches its
// model worker before this foreground handshake resolves.
import type { Plugin as V2Plugin } from "@opencode/plugin"
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

async function observeChildSessions(
  events: AsyncIterable<{ type?: string; data?: { sessionID?: string; parentID?: string } }>,
  childSessions: Set<string>,
): Promise<void> {
  try {
    for await (const event of events) {
      if (event.type === "session.created" && event.data?.sessionID && event.data.parentID) {
        childSessions.add(event.data.sessionID)
      } else if (event.type === "session.deleted" && event.data?.sessionID) {
        childSessions.delete(event.data.sessionID)
      }
    }
  } catch {
    // Event observation is only used to reject child prompts. A disconnected
    // stream must not interfere with OpenCode prompt admission.
  }
}

async function isChildSession(
  session: Pick<V2Plugin.SessionDomain, "get">,
  sessionID: string,
  childSessions: Set<string>,
): Promise<boolean> {
  if (childSessions.has(sessionID)) return true

  try {
    return Boolean((await session.get({ sessionID })).parentID)
  } catch {
    return false
  }
}

const HerdrWorktreeIdentityV2Plugin = {
  id: "herdr-worktree-identity",
  async setup({ event, session }) {
    if (!handoffWorktreeIdentity || process.env.HERDR_ENV !== "1" || process.env.HERDR_WORKTREE_IDENTITY_ACTIVE) return

    const childSessions = new Set<string>()
    const controller = new AbortController()
    const observing = observeChildSessions(event.subscribe({ signal: controller.signal }), childSessions)

    const registration = await session.hook("prompt", async ({ prompt, sessionID }) => {
      if (await isChildSession(session, sessionID, childSessions) || prompt.text.trim() === "") return

      await handoffWorktreeIdentity("opencode", sessionID, prompt.text)
    })

    return async () => {
      controller.abort()
      await registration.dispose()
      await observing
    }
  },
} satisfies V2Plugin.Plugin

export default HerdrWorktreeIdentityV2Plugin
