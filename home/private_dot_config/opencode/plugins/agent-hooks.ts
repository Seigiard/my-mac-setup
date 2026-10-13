// @ts-nocheck
// Type checking is off here for the same reason herdr's own managed extensions
// turn it off: this file is checked out in a plain dotfiles repo with no
// node_modules, and only resolves its imports once deployed under
// ~/.config/opencode/, where opencode's own dependencies live.
import type { Plugin } from "@opencode-ai/plugin"
import { lstatSync, readlinkSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import type { Decision, ToolEventValue } from "../../../dot_local/lib/agent-hooks/types.ts"

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

// Adapter modules can be re-evaluated while their runtime imports keep the
// prior core resident. Keying by dispatch preserves that loaded identity until
// the runtime actually resolves a different core module.
const RESIDENT_CORE_HASHES = Symbol.for("agent-hooks.opencode.resident-core-hashes")

type ResidentCoreRegistryHost = {
  [key: symbol]: Map<unknown, string> | undefined
}

const residentCoreRegistryHost = globalThis as typeof globalThis & ResidentCoreRegistryHost

const residentCoreHashes: Map<unknown, string> =
  residentCoreRegistryHost[RESIDENT_CORE_HASHES] ?? (residentCoreRegistryHost[RESIDENT_CORE_HASHES] = new Map())

function residentCoreHash(dispatch: unknown, coreHash: () => string): string {
  const known = residentCoreHashes.get(dispatch)

  if (known !== undefined) return known

  const hash = coreHash()
  residentCoreHashes.set(dispatch, hash)

  return hash
}

// Load-time import rather than per-call (KTD5): a failure is front-loaded into
// a plugin that registers nothing, which is the honest fail-open shape — an
// installed handler that silently allows would look alive to a reader.
let dispatch: ((client: string, rawEvent: ToolEventValue) => Decision) | undefined

try {
  const core = await import(join(CORE_DIR, "index.ts"))
  dispatch = core.dispatch

  if (dispatch && HOME !== "") {
    try {
      const { coreHash, writeMarker } = await import(join(CORE_DIR, "selfcheck.ts"))
      // Hashing disk here would mislabel a cached dispatch after an apply.
      writeMarker(CLIENT, {
        stateDir: join(HOME, ".local", "state", "agent-hooks"),
        hash: residentCoreHash(core.dispatch, coreHash),
      })
    } catch {
      // A marker this session cannot write leaves its identity unknown, which is
      // what selfcheck already reports for a session it has no evidence about.
    }
  }
} catch {
  dispatch = undefined
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

async function loadV2Dispatch(home: string): Promise<typeof dispatch> {
  try {
    const corePath = join(home, ".local", "lib", "agent-hooks")
    const coreDir = lstatSync(corePath).isSymbolicLink()
      ? resolve(dirname(corePath), readlinkSync(corePath))
      : corePath
    const core = await import(join(coreDir, "index.ts"))

    if (core.dispatch && home !== "") {
      try {
        const { coreHash, writeMarker } = await import(join(coreDir, "selfcheck.ts"))
        // Hashing disk here would mislabel a cached dispatch after an apply.
        writeMarker(CLIENT, {
          stateDir: join(home, ".local", "state", "agent-hooks"),
          hash: residentCoreHash(core.dispatch, coreHash),
        })
      } catch {
        // Missing identity evidence is diagnostic only and must not disable policy.
      }
    }

    return core.dispatch
  } catch {
    return undefined
  }
}

// V1 reads server() from the default definition; V2 reads setup(). Both call
// one adapter, so each loader registers exactly one Hooks handler.
export default {
  id: "agent-hooks",
  server: AgentHooksPlugin,
  async setup(ctx: { tool: { hook: (name: string, handler: (event: unknown) => Promise<void>) => Promise<unknown> } }) {
    const v2Dispatch = await loadV2Dispatch(process.env.HOME ?? "")

    if (!v2Dispatch) return

    await ctx.tool.hook("execute.before", async (event) => {
      let decision: Decision | undefined

      try {
        decision = v2Dispatch(CLIENT, event as ToolEventValue)
      } catch {
        return
      }

      if (decision?.verdict === "block") throw new Error(decision.reason)
    })
  },
}
