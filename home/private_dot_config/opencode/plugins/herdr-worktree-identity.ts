// @ts-nocheck
// OpenCode prompt adapter for herdr-worktree-identity. The engine detaches its
// model worker before this foreground handshake resolves.
import type { Plugin as V1Plugin } from "@opencode-ai/plugin"
import type { Plugin as V2Plugin } from "@opencode/plugin"
import { homedir } from "node:os"
import { join } from "node:path"

let defineV2Plugin: ((plugin: V2Plugin.Plugin) => V2Plugin.Plugin) | undefined
let handoffWorktreeIdentity:
  | ((agent: "opencode", sessionID: string, prompt: string) => Promise<void>)
  | undefined

try {
  ;({ Plugin: { define: defineV2Plugin } } = await import("@opencode/plugin"))
} catch {
  defineV2Plugin = undefined
}

try {
  ;({ handoffWorktreeIdentity } = await import(
    join(process.env.HOME || homedir(), ".local", "lib", "agent-hooks", "worktree-identity.ts"),
  ))
} catch {
  handoffWorktreeIdentity = undefined
}

export const HerdrWorktreeIdentityPlugin: V1Plugin = async () => {
  if (!handoffWorktreeIdentity || process.env.HERDR_ENV !== "1" || process.env.HERDR_WORKTREE_IDENTITY_ACTIVE) return {}

  const childSessions = new Set<string>()

  return {
    "chat.message": async (input, output) => {
      const sessionID = input?.sessionID

      if (!sessionID || childSessions.has(sessionID)) return

      const prompt = (Array.isArray(output?.parts) ? output.parts : [])
        .flatMap((part: { type: string; text?: string }) => part?.type === "text" && part.text !== undefined ? [part.text] : [])
        .join("\n")

      if (prompt.trim() !== "") await handoffWorktreeIdentity("opencode", sessionID, prompt)
    },
    event: async ({ event }) => {
      const type = event?.type
      const info = event?.properties?.info

      if (type === "session.deleted" && info?.id) childSessions.delete(info.id)
      else if (info?.id && info.parentID) childSessions.add(info.id)
    },
  }
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
      if (await isChildSession(session, sessionID, childSessions) || typeof prompt.text !== "string" || prompt.text.trim() === "") return

      await handoffWorktreeIdentity("opencode", sessionID, prompt.text)
    })

    return async () => {
      controller.abort()
      await registration.dispose()
      await observing
    }
  },
} satisfies V2Plugin.Plugin

export default defineV2Plugin?.(HerdrWorktreeIdentityV2Plugin) ?? HerdrWorktreeIdentityV2Plugin
