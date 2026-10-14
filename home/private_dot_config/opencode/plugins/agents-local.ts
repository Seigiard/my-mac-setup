// @ts-nocheck
// Type checking is off: this file is checked out in a plain dotfiles repo with no
// node_modules, and only resolves its imports once deployed under ~/.config/opencode/,
// where opencode's own dependencies live.
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

let isGeneratedLocalInstructionsBlock: ((block: string) => boolean) | undefined

try {
  ;({ buildLocalInstructions, isGeneratedLocalInstructionsBlock } = await import(MODULE_PATH))
} catch {
  buildLocalInstructions = undefined
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

export default plugin
