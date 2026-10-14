// @ts-nocheck
// OpenCode prompt adapter for herdr-worktree-identity. The engine detaches its
// model worker before this foreground handshake resolves.
import type { Plugin as V2Plugin } from "@opencode/plugin"
import { homedir } from "node:os"
import { join } from "node:path"

let handoffWorktreeIdentity:
  | ((agent: "opencode", sessionID: string, prompt: string) => Promise<void>)
  | undefined

let recordSessionDirectory: ((sessionID: string, directory: string) => void) | undefined

try {
  ;({ handoffWorktreeIdentity, recordSessionDirectory } = await import(
    join(process.env.HOME || homedir(), ".local", "lib", "agent-hooks", "worktree-identity.ts"),
  ))
} catch {
  handoffWorktreeIdentity = undefined
  recordSessionDirectory = undefined
}

type SessionEvent = {
  type?: string
  data?: { sessionID?: string; parentID?: string; location?: { directory?: string } }
}

// `/cd` and workspace moves change a session's location without changing the
// OpenCode process cwd, which is all herdr sees on the pane.
async function observeSessions(events: AsyncIterable<SessionEvent>, childSessions: Set<string>): Promise<void> {
  try {
    for await (const event of events) {
      if (event.type === "session.created" && event.data?.sessionID && event.data.parentID) {
        childSessions.add(event.data.sessionID)
      } else if (event.type === "session.deleted" && event.data?.sessionID) {
        childSessions.delete(event.data.sessionID)
      } else if (event.type === "session.moved" && event.data?.sessionID && event.data.location?.directory) {
        recordSessionDirectory?.(event.data.sessionID, event.data.location.directory)
      }
    }
  } catch {
    // A disconnected stream must not interfere with OpenCode prompt admission.
    // The prompt hook still records the location before each handoff.
  }
}

async function recordCurrentDirectory(session: Pick<V2Plugin.SessionDomain, "get">, sessionID: string): Promise<void> {
  try {
    const directory = (await session.get({ sessionID })).location?.directory

    if (directory) recordSessionDirectory?.(sessionID, directory)
  } catch {
    // Without a location the engine falls back to the pane cwd, as before.
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
    const observing = observeSessions(event.subscribe({ signal: controller.signal }), childSessions)

    const registration = await session.hook("prompt", async ({ prompt, sessionID }) => {
      if (await isChildSession(session, sessionID, childSessions) || prompt.text.trim() === "") return

      await recordCurrentDirectory(session, sessionID)
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
