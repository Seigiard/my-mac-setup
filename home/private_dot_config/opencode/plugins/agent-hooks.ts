// @ts-nocheck
// Type checking is off here for the same reason herdr's own managed extensions
// turn it off: this file is checked out in a plain dotfiles repo with no
// node_modules, and only resolves its imports once deployed under
// ~/.config/opencode/, where opencode's own dependencies live.
import type { Plugin } from "@opencode-ai/plugin"
import { join } from "node:path"

// opencode transport for the shared agent-hooks dispatch core.
//
// Every policy lives in ~/.local/lib/agent-hooks; this file only translates.
// In: opencode hands `tool.execute.before` the tool name on `input` and the
// call arguments on `output`, so the core's opencode dialect is composed here
// as {tool, args}. Out: a deny is a thrown Error whose message is the core's
// already-prefixed reason; an allow is a plain return.
//
// Fails open in every direction (R4): no core on disk, a core that will not
// import, or a dispatch that throws must all let the tool call proceed.

const CLIENT = "opencode"
const HOME = process.env.HOME ?? ""
const CORE_DIR = join(HOME, ".local", "lib", "agent-hooks")

// Load-time import rather than per-call (KTD5): a failure is front-loaded into
// a plugin that registers nothing, which is the honest fail-open shape — an
// installed handler that silently allows would look alive to a reader.
let dispatch: ((client: string, rawEvent: unknown) => any) | undefined
try {
  ;({ dispatch } = await import(join(CORE_DIR, "index.ts")))
} catch {
  dispatch = undefined
}

// The marker records which core this resident session actually loaded, so
// selfcheck can tell a stale session from a current one after an apply (KTD5).
// Best-effort and separate from the gate above: no marker is a reporting gap,
// not a reason to stop enforcing.
if (dispatch && HOME !== "") {
  try {
    const { writeMarker } = await import(join(CORE_DIR, "selfcheck.ts"))
    writeMarker(CLIENT, { stateDir: join(HOME, ".local", "state", "agent-hooks") })
  } catch {
    // A marker this session cannot write leaves its identity unknown, which is
    // what selfcheck already reports for a session it has no evidence about.
  }
}

export const AgentHooksPlugin: Plugin = async () => {
  if (!dispatch) return {}

  return {
    "tool.execute.before": async (input, output) => {
      let decision: any
      try {
        decision = dispatch(CLIENT, { tool: input?.tool, args: output?.args ?? {} })
      } catch {
        // Deliberately outside the throw below. The shipped guards recognised
        // their own deny by a fixed reason prefix; the prefix is the policy's
        // now, so a catch wrapped around the throw would have to guess which
        // errors are denies and would swallow one it guessed wrong about.
        return
      }
      if (decision?.verdict === "block") throw new Error(decision.reason)
    },
  }
}
