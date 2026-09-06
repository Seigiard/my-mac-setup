// Shared types for the agent-hooks dispatch core.
//
// Layering invariant (KTD1): client identity lives in the registry profiles
// only. A policy module never names a client; applicability is derived.

export type ClientId = "claude" | "opencode" | "pi";

/** Canonical tool kinds. Client-specific spellings are registry data. */
export type ToolKind = "edit" | "write" | "bash" | "fff-grep" | "web-fetch";

export type OutcomeKind = "block" | "context";

export type Decision =
  | { verdict: "allow" }
  | { verdict: "block"; reason: string }
  | { verdict: "context"; text: string };

export const ALLOW: Decision = Object.freeze({ verdict: "allow" });

export function block(reason: string): Decision {
  return { verdict: "block", reason };
}

export function context(text: string): Decision {
  return { verdict: "context", text };
}

/**
 * The client-independent payload a policy sees. Every dialect normalizes into
 * this shape; absent fields are the empty string, never undefined, so the three
 * dialects compare equal field-by-field.
 */
export type EventPayload = {
  filePath: string;
  content: string;
  command: string;
  query: string;
  url: string;
};

export type NormalizedEvent = EventPayload & {
  client: ClientId;
  /** The spelling the client used, kept for adapter-side diagnostics. */
  clientToolName: string;
  tool: ToolKind;
};

export type Policy = {
  name: string;
  /** Canonical tools this policy inspects. */
  tools: ToolKind[];
  /** Outcomes this policy can produce; a profile must support all of them. */
  outcomes: OutcomeKind[];
  /** Token that lets an author opt out in-band, e.g. "oracle:". */
  escapeHatch?: string;
  /**
   * Known-bad input this policy must block, used by the selfcheck canary to
   * prove the route is alive. Required of every block-capable policy.
   */
  canary?: { tool: ToolKind; payload: Partial<EventPayload> };
  /** Pure, synchronous, bounded — no I/O (KTD7). */
  evaluate: (event: NormalizedEvent) => Decision | undefined;
};

export type ClientProfile = {
  client: ClientId;
  /** Client tool spelling -> canonical kind. Casing is per client. */
  tools: Record<string, ToolKind>;
  outcomes: OutcomeKind[];
};

export type Registry = {
  profiles: ClientProfile[];
  policies: Policy[];
};

export function emptyPayload(): EventPayload {
  return { filePath: "", content: "", command: "", query: "", url: "" };
}

export function payloadOf(event: NormalizedEvent): EventPayload {
  return {
    filePath: event.filePath,
    content: event.content,
    command: event.command,
    query: event.query,
    url: event.url,
  };
}
