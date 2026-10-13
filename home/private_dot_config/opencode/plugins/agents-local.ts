// @ts-nocheck
import { join } from "node:path"

const HOME = process.env.HOME ?? ""
const MODULE_PATH = join(HOME, ".local", "lib", "agent-hooks", "local-instructions.ts")
const HOOKS = ["context", "compaction", "generate", "title"]

let buildLocalInstructions: ((cwd: string) => Promise<{ block?: string }>) | undefined
let heading: string | undefined
let defineV2: ((plugin: { id: string; setup: (ctx: unknown) => Promise<void> }) => unknown) | undefined

try {
  ;({ buildLocalInstructions, LOCAL_INSTRUCTIONS_HEADING: heading } = await import(MODULE_PATH))
} catch {
  buildLocalInstructions = undefined
}

try {
  ;({ Plugin: { define: defineV2 } } = await import("@opencode/plugin"))
} catch {
  defineV2 = undefined
}

async function localInstructions(directory: string): Promise<string | undefined> {
  if (!buildLocalInstructions || !heading) return

  try {
    return (await buildLocalInstructions(directory)).block
  } catch {
    // Local instructions are additive. A failed selection leaves the request
    // exactly as OpenCode built it instead of injecting an uncertain path.
    return
  }
}

function hasHeading(entry: unknown): boolean {
  if (typeof entry === "string") return entry.includes(heading ?? "")

  return (
    typeof entry === "object" &&
    entry !== null &&
    (entry as { type?: unknown }).type === "text" &&
    typeof (entry as { text?: unknown }).text === "string" &&
    (entry as { text: string }).text.includes(heading ?? "")
  )
}

const v2Plugin = defineV2?.({
  id: "agents-local",
  async setup(ctx) {
    if (!buildLocalInstructions || !heading) return

    const inject = async (request: { sessionID?: string; system: unknown[] }) => {
      if (!request.sessionID || request.system.some(hasHeading)) return

      let session: { location?: { directory?: string } }

      try {
        session = await ctx.session.get({ sessionID: request.sessionID })
      } catch {
        return
      }

      const directory = session.location?.directory
      if (!directory) return

      const block = await localInstructions(directory)
      if (block) request.system.push({ type: "text", text: block })
    }

    await Promise.all(HOOKS.map((hook) => ctx.session.hook(hook, inject)))
  },
})

// V1 remains the normal pin until the migration lands. It also remains the
// existing owner for shared selection regressions; V2 loads `v2Plugin` below.
export async function AgentsLocalPlugin({ directory }: { directory?: string }) {
  if (!directory || !heading) return {}

  return {
    "experimental.chat.system.transform": async (_input: unknown, output: { system?: string[] }) => {
      const system = output?.system
      if (!Array.isArray(system) || system.some(hasHeading)) return

      const block = await localInstructions(directory)
      if (block) system.push(block)
    },
  }
}

export default v2Plugin ?? AgentsLocalPlugin
