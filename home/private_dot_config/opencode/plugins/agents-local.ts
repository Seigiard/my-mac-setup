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

type V1Plugin = {
  "experimental.chat.system.transform"?: (
    input: Record<string, never>,
    output: { system?: string[] },
  ) => Promise<void>
}

let buildLocalInstructions: ((cwd: string) => Promise<LocalInstructionsBlock>) | undefined

let isGeneratedLocalInstructionsBlock: ((block: string) => boolean) | undefined

let defineV2: ((plugin: V2Plugin) => V2Plugin) | undefined

try {
  ;({ buildLocalInstructions, isGeneratedLocalInstructionsBlock } = await import(MODULE_PATH))
} catch {
  buildLocalInstructions = undefined
}

try {
  ;({ Plugin: { define: defineV2 } } = await import("@opencode/plugin"))
} catch {
  defineV2 = undefined
}

async function localInstructions(directory: string): Promise<string | undefined> {
  try {
    return (await buildLocalInstructions(directory)).block
  } catch {
    // Do not restore stale instructions when selection fails.
    return undefined
  }
}

const plugin = {
  id: "agents-local",
  server: AgentsLocalPlugin,
  async setup(ctx) {
    if (!buildLocalInstructions || !isGeneratedLocalInstructionsBlock) return

    const inject = async (request: SessionRequest) => {
      const retained = request.system.filter((part) => !isGeneratedLocalInstructionsBlock(part.text))
      request.system.splice(0, request.system.length, ...retained)

      try {
        const session = await ctx.session.get({ sessionID: request.sessionID })
        const directory = session?.location?.directory

        if (!directory) return

        const block = await localInstructions(directory)

        if (block) request.system.push({ type: "text", text: block } satisfies SystemPart)
      } catch {
        return
      }
    }

    await Promise.all(HOOKS.map((hook) => ctx.session.hook(hook, inject)))
  },
}

// V1 remains the normal pin until the upgrade lands; the dynamic V2 bridge
// keeps this file loadable in that host while preserving V1 selection coverage.
export async function AgentsLocalPlugin({ directory }: { directory?: string }): Promise<V1Plugin> {
  if (!buildLocalInstructions || !isGeneratedLocalInstructionsBlock || !directory) return {}

  return {
    "experimental.chat.system.transform": async (_input: Record<string, never>, output: { system?: string[] }) => {
      const system = output?.system

      if (!Array.isArray(system)) return

      const retained = system.filter((entry) => !isGeneratedLocalInstructionsBlock(entry))
      system.splice(0, system.length, ...retained)

      const block = await localInstructions(directory)

      if (block) system.push(block)
    },
  }
}

export default defineV2 ? defineV2(plugin) : plugin
