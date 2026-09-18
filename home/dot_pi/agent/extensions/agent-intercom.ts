// @ts-nocheck
import { join } from "node:path"

let intercomExtension: ((pi: any) => any) | undefined
const shouldLoad =
  process.env.HERDR_ENV === "1" && process.env.HERDR_AGENT_INTERCOM_PI_LOAD === "1"
delete process.env.HERDR_AGENT_INTERCOM_PI_LOAD
if (shouldLoad) {
  const root = join(
    process.env.HOME ?? "",
    ".local",
    "share",
    "agent-intercom",
    "node_modules",
    "@dataforxyz",
    "agent-intercom-pi",
  )
  try {
    const module = await import(join(root, "index.ts"))
    if (typeof module.default === "function") intercomExtension = module.default
  } catch {
    // Intercom is additive; an incomplete optional install must not block Pi.
  }
}

export default function agentIntercom(pi: any) {
  return intercomExtension?.(pi)
}
