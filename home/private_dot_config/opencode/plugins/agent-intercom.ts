// @ts-nocheck
import type { Plugin } from "@opencode-ai/plugin"
import { join } from "node:path"

let intercomPlugin: Plugin | undefined
const intercomName = process.env.OPENCODE_INTERCOM_NAME?.trim()
if (process.env.HERDR_ENV === "1" && intercomName) {
  const root = join(
    process.env.HOME ?? "",
    ".local",
    "share",
    "agent-intercom",
    "node_modules",
    "@dataforxyz",
    "agent-intercom-opencode",
  )
  try {
    const module = await import(join(root, "dist", "plugin.mjs"))
    if (typeof module.default === "function") intercomPlugin = module.default
  } catch {
    // Intercom is additive; an incomplete optional install must not block OpenCode.
  }
}
delete process.env.OPENCODE_INTERCOM_NAME

// OpenCode treats every export as a plugin factory, so expose exactly one and
// deliberately omit the package's TUI entrypoint.
export const AgentIntercomPlugin: Plugin = async (input) => {
  if (!intercomPlugin || !intercomName) return {}

  const previousName = process.env.OPENCODE_INTERCOM_NAME
  process.env.OPENCODE_INTERCOM_NAME = intercomName
  try {
    return await intercomPlugin(input)
  } finally {
    if (previousName === undefined) delete process.env.OPENCODE_INTERCOM_NAME
    else process.env.OPENCODE_INTERCOM_NAME = previousName
  }
}
