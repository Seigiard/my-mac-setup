// @ts-nocheck
// Type checking is off here for the same reason the other managed opencode
// plugins turn it off: this file is checked out in a plain dotfiles repo with
// no node_modules, and only resolves its imports once deployed under
// ~/.config/opencode/, where opencode's own dependencies live.
import type { Plugin } from "@opencode-ai/plugin"
import { join } from "node:path"

// opencode transport for the shared local-instructions module.
//
// Selection, the symlink-escape check, the size cap and the emitted block all
// live in ~/.local/lib/agent-hooks/local-instructions.ts and are shared with
// the pi extension, so the safety checks exist once (R7). pi's ui.notify
// warnings are dropped here: opencode has no equivalent channel (KTD11).
//
// Generated blocks are replaced before every request. This makes an edited
// file, a missing file, or a changed session directory retract stale context.

const HOME = process.env.HOME ?? ""

const MODULE_PATH = join(HOME, ".local", "lib", "agent-hooks", "local-instructions.ts")

// Load-time import rather than per-call (KTD5): a failure is front-loaded into
// a plugin that registers nothing, which is the honest degradation — a
// registered hook that never appends would look alive to a reader.
let buildLocalInstructions: ((cwd: string) => Promise<{ block?: string }>) | undefined

let heading: string | undefined

try {
  ;({ buildLocalInstructions, LOCAL_INSTRUCTIONS_HEADING: heading } = await import(MODULE_PATH))
} catch {
  buildLocalInstructions = undefined
}

export const AgentsLocalPlugin: Plugin = async ({ directory }) => {
  if (!buildLocalInstructions || !heading || !directory) return {}

  return {
    "experimental.chat.system.transform": async (_input, output) => {
      const system = output?.system

      if (!Array.isArray(system)) return

      const retained = system.filter((entry: string) => !entry.includes(heading))
      system.length = 0
      system.push(...retained)

      let block: string | undefined

      try {
        ;({ block } = await buildLocalInstructions(directory))
      } catch {
        // A selection that throws leaves the prompt exactly as opencode built
        // it; local instructions are additive, so degrading to none is safe.
        return
      }

      if (block) system.push(block)
    },
  }
}

export default {
  id: "agents-local",
  async setup(ctx) {
    if (!buildLocalInstructions || !heading) return

    await ctx.session.hook("context", async (event) => {
      const system = event.system
      const retained = system.filter((part) => !part.text.includes(heading))
      system.splice(0, system.length, ...retained)

      let session

      try {
        session = await ctx.session.get({ sessionID: event.sessionID })
      } catch {
        return
      }

      const directory = session?.location?.directory

      if (!directory) return

      try {
        const { block } = await buildLocalInstructions(directory)

        if (block) system.push({ type: "text", text: block })
      } catch {
        return
      }
    })
  },
}
