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
// Idempotence is a heading check, not a call counter. opencode rebuilds the
// system array per request (observed: a marker pushed on one turn is absent
// from the next), but the guard also holds if a future opencode hands the hook
// what a previous call accumulated — which is what makes the append safe
// under either semantics (KTD11).
//
// The `experimental.` prefix is an accepted upgrade-fragility risk: a rename
// silently stops the injection rather than breaking a session.

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
      if (system.some((entry) => typeof entry === "string" && entry.includes(heading))) return

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
