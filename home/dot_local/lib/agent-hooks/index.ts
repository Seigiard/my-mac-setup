// Dispatch core: normalize, select applicable policies, run them in registry
// order, first deny wins. Every failure path falls open (R4).

import { normalizeEvent } from "./normalize.ts";
import { CORE_REGISTRY, policiesFor, profileFor } from "./registry.ts";
import type { ClientId, Decision, NormalizedEvent, Policy, Registry } from "./types.ts";
import { ALLOW } from "./types.ts";

export * from "./types.ts";
export {
  CLIENT_PROFILES,
  CORE_REGISTRY,
  applicableClients,
  createRegistry,
  isApplicable,
  isBlockCapable,
  policiesFor,
  profileFor,
  registrySnapshot,
} from "./registry.ts";
export { encodeEvent, normalizeEvent } from "./normalize.ts";

export const DISABLE_ENV_VAR = "AGENT_HOOKS_DISABLE";

export type DispatchOptions = {
  registry?: Registry;
  /** Process environment only; never the intercepted call's arguments (R8). */
  env?: Record<string, string | undefined>;
};

/**
 * Read from the client process environment alone. An agent must not be able to
 * disable a policy from inside the very call the policy is inspecting, so the
 * normalized event is not a source here (R8).
 */
export function disabledPolicyNames(env: Record<string, string | undefined>): Set<string> {
  const raw = env[DISABLE_ENV_VAR];
  if (typeof raw !== "string" || raw === "") return new Set();
  return new Set(
    raw
      .split(",")
      .map((name) => name.trim())
      .filter((name) => name !== ""),
  );
}

export type DispatchTrace = { invoked: string[]; decision: Decision };

function runPolicies(event: NormalizedEvent, policies: Policy[]): DispatchTrace {
  const invoked: string[] = [];
  let deferred: Decision | undefined;

  for (const policy of policies) {
    invoked.push(policy.name);
    let decision: Decision;
    try {
      decision = policy.evaluate(event) ?? ALLOW;
    } catch {
      // R4 fail-open pin: a policy exception must never block the tool call.
      decision = ALLOW;
    }
    if (decision.verdict === "block") return { invoked, decision };
    if (decision.verdict === "context" && !deferred) deferred = decision;
  }

  return { invoked, decision: deferred ?? ALLOW };
}

/** Full pipeline with the list of policies actually invoked, for tests and selfcheck. */
export function dispatchTraced(
  client: ClientId | string,
  rawEvent: unknown,
  options: DispatchOptions = {},
): DispatchTrace {
  const registry = options.registry ?? CORE_REGISTRY;
  const env = options.env ?? process.env;

  try {
    const profile = profileFor(registry, client);
    if (!profile) return { invoked: [], decision: ALLOW };

    const event = normalizeEvent(client, rawEvent, registry);
    if (!event) return { invoked: [], decision: ALLOW };

    const disabled = disabledPolicyNames(env);
    const policies = policiesFor(registry, profile, event.tool).filter(
      (policy) => !disabled.has(policy.name),
    );
    if (policies.length === 0) return { invoked: [], decision: ALLOW };

    return runPolicies(event, policies);
  } catch {
    return { invoked: [], decision: ALLOW };
  }
}

export function dispatch(
  client: ClientId | string,
  rawEvent: unknown,
  options: DispatchOptions = {},
): Decision {
  return dispatchTraced(client, rawEvent, options).decision;
}
