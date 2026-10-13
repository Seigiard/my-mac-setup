// @ts-nocheck
// This runs under the pinned V1 host, where the V2 package is absent at runtime.
// Type-only V2 imports document the upgrade contract without changing that load path.
import { join } from "node:path"
import type { SystemPart } from "@opencode/ai"
import type { Plugin as OpenCodePlugin } from "@opencode/plugin"
import type { SessionRequest } from "@opencode/plugin/promise/session"

const HOME = process.env.HOME ?? ""

const MODULE_PATH = join(HOME, ".local", "lib", "agent-hooks", "local-instructions.ts")

const HOOKS = ["context", "compaction", "generate", "title"]

type LocalInstructionsBlock = { block?: string }

type V2Plugin = OpenCodePlugin.Plugin

let buildLocalInstructions: ((cwd: string) => Promise<LocalInstructionsBlock>) | undefined

let heading: string | undefined

let isGeneratedLocalInstructionsBlock: ((block: string) => boolean) | undefined

let defineV2: ((plugin: V2Plugin) => V2Plugin) | undefined

try {
  ;({ buildLocalInstructions, LOCAL_INSTRUCTIONS_HEADING: heading, isGeneratedLocalInstructionsBlock } = await import(MODULE_PATH))
} catch {
  buildLocalInstructions = undefined
}

try {
  ;({ Plugin: { define: defineV2 } } = await import("@opencode/plugin"))
} catch {
  defineV2 = undefined
}

async function localInstructions(directory: string): Promise<{ block?: string; failed: boolean }> {
  if (!buildLocalInstructions || !heading) return { failed: true }

  try {
    return { block: (await buildLocalInstructions(directory)).block, failed: false }
  } catch {
    // Local instructions are additive. A failed selection leaves the request
    // exactly as OpenCode built it instead of injecting an uncertain path.
    return { failed: true }
  }
}

function hasLocalInstructionsHeading(entry: string): boolean {
  return entry.includes(heading ?? "")
}

const v2Plugin = defineV2?.({
  id: "agents-local",
  async setup(ctx) {
    if (!buildLocalInstructions || !heading || !isGeneratedLocalInstructionsBlock) return

    const inject = async (request: SessionRequest) => {
      try {
        const session = await ctx.session.get({ sessionID: request.sessionID })
        const result = await localInstructions(session.location.directory)

        if (result.failed) return

        const system = request.system.filter((part) => !isGeneratedLocalInstructionsBlock(part.text))

        if (result.block) system.push({ type: "text", text: result.block } satisfies SystemPart)

        request.system.splice(0, request.system.length, ...system)
      } catch {
        return
      }
    }

    await Promise.all(HOOKS.map((hook) => ctx.session.hook(hook, inject)))
  },
})

// V1 remains the normal pin until the upgrade lands; the dynamic V2 bridge
// keeps this file loadable in that host while preserving V1 selection coverage.
export async function AgentsLocalPlugin({ directory }: { directory?: string }) {
  if (!directory || !heading) return {}

  return {
    "experimental.chat.system.transform": async (_input: Record<string, never>, output: { system?: string[] }) => {
      const system = output.system

      if (!system || system.some(hasLocalInstructionsHeading)) return

      const { block } = await localInstructions(directory)

      if (block) system.push(block)
    },
  }
}

export default v2Plugin ?? AgentsLocalPlugin
