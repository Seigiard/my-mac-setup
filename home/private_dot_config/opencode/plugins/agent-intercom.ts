// @ts-nocheck
import type { Plugin } from "@opencode-ai/plugin"
import { join } from "node:path"

let intercomPlugin: Plugin | undefined

const intercomName = process.env.OPENCODE_INTERCOM_NAME?.trim()

function withCloneableResponses(client: any): any {
  if (!client) return client
  const namespaces = new Set(["session", "tui"])

  return new Proxy(client, {
    get(target, property, receiver) {
      const namespace = Reflect.get(target, property, receiver)

      if (!namespaces.has(property as string) || !namespace) return namespace

      return new Proxy(namespace, {
        get(namespaceTarget, method, namespaceReceiver) {
          const value = Reflect.get(namespaceTarget, method, namespaceReceiver)

          if (typeof value !== "function") return value

          return async (...args: any[]) => {
            const result = await Reflect.apply(value, namespaceTarget, args)
            const response = result?.response

            if (!response?.bodyUsed) return result

            // The SDK has already consumed this body. Preserve response metadata
            // while letting optional plugin diagnostics clone an empty body.
            const cloneableResponse = new Proxy(response, {
              get(responseTarget, responseProperty) {
                if (responseProperty === "clone") {
                  return () => new Response(null, {
                    status: responseTarget.status,
                    statusText: responseTarget.statusText,
                    headers: responseTarget.headers,
                  })
                }

                const responseValue = Reflect.get(responseTarget, responseProperty, responseTarget)

                return typeof responseValue === "function"
                  ? responseValue.bind(responseTarget)
                  : responseValue
              },
            })

            return { ...result, response: cloneableResponse }
          }
        },
      })
    },
  })
}

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

// Do not leak this session's alias to nested OpenCode processes.
delete process.env.OPENCODE_INTERCOM_NAME

// OpenCode treats every export as a plugin factory, so expose exactly one and
// deliberately omit the package's TUI entrypoint.
export const AgentIntercomPlugin: Plugin = async (input) => {
  if (!intercomPlugin || !intercomName) return {}

  process.env.OPENCODE_INTERCOM_NAME = intercomName

  try {
    return await intercomPlugin({ ...input, client: withCloneableResponses(input.client) })
  } catch {
    return {}
  } finally {
    delete process.env.OPENCODE_INTERCOM_NAME
  }
}
