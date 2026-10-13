// @ts-nocheck
import { execFile } from "node:child_process"
import { homedir } from "node:os"
import { join } from "node:path"

const HEADING = "## Herdr Agent Resource Context (generated)"
const HOOKS = ["context", "compaction", "generate", "title"]
const RESOURCE_CLI =
  process.env.HERDR_RESOURCE_CONTEXT_CLI ??
  join(process.env.HOME || homedir(), ".local", "bin", "herdr-resource-tree")

let defineV2: ((plugin: { id: string; setup: (ctx: unknown) => Promise<void> }) => unknown) | undefined

try {
  ;({ Plugin: { define: defineV2 } } = await import("@opencode/plugin"))
} catch {
  defineV2 = undefined
}

function queryContext(sessionID: string): Promise<string | undefined> {
  return new Promise((resolve) => {
    execFile(
      RESOURCE_CLI,
      ["--context", "--caller-agent", "opencode", "--caller-session-id", sessionID],
      { encoding: "utf8", maxBuffer: 64 * 1024 },
      (error, stdout) => resolve(error ? undefined : stdout.replace(/\r?\n$/, "")),
    )
  })
}

function generatedContext(entry: unknown): boolean {
  const text =
    typeof entry === "string"
      ? entry
      : typeof entry === "object" && entry !== null && (entry as { type?: unknown }).type === "text"
        ? (entry as { text?: unknown }).text
        : undefined

  return typeof text === "string" && (text === HEADING || text.startsWith(`${HEADING}\n`))
}

function unavailable(reason: string): string {
  return `${HEADING}\nHerdr resource context unavailable: ${reason}. This must not be treated as an empty resource branch.`
}

async function resourceContext(sessionID?: string): Promise<string | undefined> {
  if (!sessionID) return unavailable("OpenCode did not expose a native session identity")

  const context = await queryContext(sessionID)
  if (context === undefined) return unavailable("the shared resource query failed")
  if (context !== "") return `${HEADING}\n${context}`
}

const v2Plugin = defineV2?.({
  id: "herdr-resource-context",
  async setup(ctx) {
    if (process.env.HERDR_ENV !== "1") return

    const inject = async (request: { sessionID?: string; system: unknown[] }) => {
      const retained = request.system.filter((entry) => !generatedContext(entry))
      request.system.length = 0
      request.system.push(...retained)

      const context = await resourceContext(request.sessionID)
      if (context) request.system.push({ type: "text", text: context })
    }

    await Promise.all(HOOKS.map((hook) => ctx.session.hook(hook, inject)))
  },
})

// V1 remains the normal pin until the migration lands. It also remains the
// existing owner for shared projection regressions; V2 loads `v2Plugin` below.
export async function HerdrResourceContextPlugin() {
  if (process.env.HERDR_ENV !== "1") return {}

  return {
    "experimental.chat.system.transform": async (input: { sessionID?: string }, output: { system?: string[] }) => {
      const system = output?.system
      if (!Array.isArray(system)) return

      const retained = system.filter((entry) => !generatedContext(entry))
      system.length = 0
      system.push(...retained)

      const context = await resourceContext(input?.sessionID)
      if (context) system.push(context)
    },
  }
}

export default v2Plugin ?? HerdrResourceContextPlugin
