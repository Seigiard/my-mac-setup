// @ts-nocheck
// Type checking is off: this file is checked out in a plain dotfiles repo with no
// node_modules, and only resolves its imports once deployed under ~/.config/opencode/,
// where opencode's own dependencies live.
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

// Adapter modules can be re-evaluated while their runtime imports keep the
// prior core resident. Keying by dispatch preserves that loaded identity until
// the runtime actually resolves a different core module.
const RESIDENT_CORE_HASHES = Symbol.for("agent-hooks.opencode.resident-core-hashes")

type Dispatch = (client: string, rawEvent: ToolEventValue) => Decision

type ResidentCoreRegistryHost = {
  [key: symbol]: Map<Dispatch, string> | undefined
}

// SAFETY: the registry lives under one process-wide symbol key that only this
// adapter writes, so the slot is absent or holds the map created below.
const residentCoreRegistryHost = globalThis as typeof globalThis & ResidentCoreRegistryHost

const residentCoreHashes: Map<Dispatch, string> =
  residentCoreRegistryHost[RESIDENT_CORE_HASHES] ?? (residentCoreRegistryHost[RESIDENT_CORE_HASHES] = new Map())

function residentCoreHash(dispatch: Dispatch, coreHash: () => string): string {
  const known = residentCoreHashes.get(dispatch)

  if (known !== undefined) return known

  const hash = coreHash()
  residentCoreHashes.set(dispatch, hash)

  return hash
}

// Load-time import rather than per-call (KTD5): a failure is front-loaded into
// a plugin that registers nothing, which is the honest fail-open shape — an
// installed handler that silently allows would look alive to a reader.
async function loadV2Dispatch(home: string): Promise<Dispatch | undefined> {
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

// The V2 host hands execute.before the native tool event; the core parses it
// with its own schema, so the adapter forwards it as the untyped event value.
type V2ToolHookHost = {
  tool: { hook: (name: "execute.before", handler: (event: ToolEventValue) => Promise<void>) => Promise<void> }
}

export default {
  id: "agent-hooks",
  async setup(ctx: V2ToolHookHost) {
    const v2Dispatch = await loadV2Dispatch(process.env.HOME ?? "")

    if (!v2Dispatch) return

    await ctx.tool.hook("execute.before", async (event) => {
      let decision: Decision | undefined

      try {
        decision = v2Dispatch(CLIENT, event)
      } catch {
        return
      }

      if (decision?.verdict === "block") throw new Error(decision.reason)
    })
  },
}
