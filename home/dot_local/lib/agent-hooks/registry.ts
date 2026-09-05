// Static per-client profiles and the applicability derivation (KTD6).
//
// A profile carries only what the code consumes: the client's tool spellings
// and the outcomes its transport can express. Arg-dialect handling is code in
// normalize.ts, not data here.

import { CORE_POLICIES } from "./policies/index.ts";
import type {
  ClientId,
  ClientProfile,
  OutcomeKind,
  Policy,
  Registry,
  ToolKind,
} from "./types.ts";

// The fff MCP tool is spelled per client: Claude namespaces it mcp__fff__grep,
// opencode flattens the server name to fff_grep (observed against the shipped
// fff MCP server, U4). Pi's spelling is still unverified, so its profile omits
// the tool and the derivation declares the policy inapplicable there
// statically instead of missing it silently (R3).
export const CLIENT_PROFILES: ClientProfile[] = [
  {
    client: "claude",
    tools: {
      Edit: "edit",
      MultiEdit: "edit",
      Write: "write",
      Bash: "bash",
      mcp__fff__grep: "fff-grep",
      WebFetch: "web-fetch",
    },
    // Only Claude's transport can return additionalContext.
    outcomes: ["block", "context"],
  },
  {
    client: "opencode",
    tools: { edit: "edit", write: "write", bash: "bash", fff_grep: "fff-grep" },
    outcomes: ["block"],
  },
  {
    client: "pi",
    tools: { edit: "edit", write: "write", bash: "bash" },
    outcomes: ["block"],
  },
];

export function createRegistry(overrides: Partial<Registry> = {}): Registry {
  return {
    profiles: overrides.profiles ?? CLIENT_PROFILES,
    policies: overrides.policies ?? CORE_POLICIES,
  };
}

export const CORE_REGISTRY: Registry = createRegistry();

export function profileFor(registry: Registry, client: ClientId | string): ClientProfile | undefined {
  return registry.profiles.find((profile) => profile.client === client);
}

export function toolKindFor(profile: ClientProfile, clientToolName: string): ToolKind | undefined {
  return Object.prototype.hasOwnProperty.call(profile.tools, clientToolName)
    ? profile.tools[clientToolName]
    : undefined;
}

export function clientToolNamesFor(profile: ClientProfile, tool: ToolKind): string[] {
  return Object.keys(profile.tools).filter((name) => profile.tools[name] === tool);
}

export function supportedToolKinds(profile: ClientProfile): ToolKind[] {
  return [...new Set(Object.values(profile.tools))];
}

/** Derived, never declared: tool presence plus outcome support (KTD6, KTD8). */
export function isApplicable(profile: ClientProfile, policy: Policy): boolean {
  const kinds = supportedToolKinds(profile);
  const toolPresent = policy.tools.some((tool) => kinds.includes(tool));
  const outcomesSupported = policy.outcomes.every((outcome: OutcomeKind) =>
    profile.outcomes.includes(outcome),
  );
  return toolPresent && outcomesSupported;
}

export function applicableClients(registry: Registry, policy: Policy): ClientId[] {
  return registry.profiles.filter((profile) => isApplicable(profile, policy)).map((p) => p.client);
}

/** Policies that run for one (client, tool) pair, in declaration order. */
export function policiesFor(registry: Registry, profile: ClientProfile, tool: ToolKind): Policy[] {
  return registry.policies.filter(
    (policy) => policy.tools.includes(tool) && isApplicable(profile, policy),
  );
}

export function isBlockCapable(policy: Policy): boolean {
  return policy.outcomes.includes("block");
}

export type RegistrySnapshot = {
  clients: Array<{ client: ClientId; tools: Record<string, ToolKind>; outcomes: OutcomeKind[] }>;
  policies: Array<{
    name: string;
    tools: ToolKind[];
    outcomes: OutcomeKind[];
    escapeHatch: string | null;
    blockCapable: boolean;
    applicableClients: ClientId[];
  }>;
};

/** The one machine-readable export; selfcheck --json and the union test read it. */
export function registrySnapshot(registry: Registry = CORE_REGISTRY): RegistrySnapshot {
  return {
    clients: registry.profiles.map((profile) => ({
      client: profile.client,
      tools: { ...profile.tools },
      outcomes: [...profile.outcomes],
    })),
    policies: registry.policies.map((policy) => ({
      name: policy.name,
      tools: [...policy.tools],
      outcomes: [...policy.outcomes],
      escapeHatch: policy.escapeHatch ?? null,
      blockCapable: isBlockCapable(policy),
      applicableClients: applicableClients(registry, policy),
    })),
  };
}
