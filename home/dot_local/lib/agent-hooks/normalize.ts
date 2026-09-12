// The three client arg dialects, in and out.
//
// Field names come from the shipped adapters, which are the authority on what
// each client actually sends:
//   claude   tool_input.content / file_path / new_string / edits[].new_string
//   opencode args.content / filePath | file_path / newString
//   pi       input.content / path / edits[].newText
// Content is aggregated across the full-content and edit fields alike: a Write
// call carries its text only in `content`, and dropping it would let full-file
// writes past every content policy.

import { profileFor, toolKindFor } from "./registry.ts";
import type {
  ClientId,
  EventPayload,
  NormalizedEvent,
  Registry,
  ToolKind,
} from "./types.ts";
import { emptyPayload } from "./types.ts";

function str(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function joinParts(parts: unknown[]): string {
  return parts.map(str).filter((part) => part !== "").join("\n");
}

function editParts(edits: unknown, field: string): string[] {
  if (!Array.isArray(edits)) return [];
  return edits.map((edit: any) => str(edit?.[field]));
}

type RawRead = { clientToolName: string; payload: EventPayload };

function readClaude(raw: any): RawRead {
  const input = raw?.tool_input ?? {};
  return {
    clientToolName: str(raw?.tool_name),
    payload: {
      filePath: str(input.file_path),
      content: joinParts([input.content, input.new_string, ...editParts(input.edits, "new_string")]),
      command: str(input.command),
      query: str(input.query),
      url: str(input.url),
    },
  };
}

function readOpencode(raw: any): RawRead {
  const args = raw?.args ?? {};
  return {
    clientToolName: str(raw?.tool),
    payload: {
      filePath: str(args.filePath) || str(args.file_path),
      content: joinParts([args.content, args.newString]),
      command: str(args.command),
      query: str(args.query),
      url: str(args.url),
    },
  };
}

function readPi(raw: any): RawRead {
  const input = raw?.input ?? {};
  const clientToolName = str(raw?.toolName);
  return {
    clientToolName,
    payload: {
      filePath: str(input.path),
      content: joinParts([input.content, ...editParts(input.edits, "newText")]),
      command: str(input.command),
      query: clientToolName === "ffgrep" ? str(input.pattern) : str(input.query),
      url: str(input.url),
    },
  };
}

const READERS: Record<ClientId, (raw: any) => RawRead> = {
  claude: readClaude,
  opencode: readOpencode,
  pi: readPi,
};

/**
 * A malformed event or an unmapped tool yields undefined, which dispatch turns
 * into allow (R4).
 */
export function normalizeEvent(
  client: ClientId | string,
  raw: unknown,
  registry: Registry,
): NormalizedEvent | undefined {
  const profile = profileFor(registry, client);
  const reader = READERS[client as ClientId];
  if (!profile || !reader) return undefined;

  let read: RawRead;
  try {
    read = reader(raw);
  } catch {
    return undefined;
  }

  const tool = toolKindFor(profile, read.clientToolName);
  if (!tool) return undefined;

  return { client: profile.client, clientToolName: read.clientToolName, tool, ...read.payload };
}

type Writer = (toolName: string, payload: EventPayload, tool: ToolKind) => unknown;

const WRITERS: Record<ClientId, Writer> = {
  claude: (toolName, payload, tool) => ({
    tool_name: toolName,
    tool_input: {
      ...(payload.filePath ? { file_path: payload.filePath } : {}),
      ...(payload.content ? (tool === "edit" ? { new_string: payload.content } : { content: payload.content }) : {}),
      ...(payload.command ? { command: payload.command } : {}),
      ...(payload.query ? { query: payload.query } : {}),
      ...(payload.url ? { url: payload.url } : {}),
    },
  }),
  opencode: (toolName, payload, tool) => ({
    tool: toolName,
    args: {
      ...(payload.filePath ? { filePath: payload.filePath } : {}),
      ...(payload.content ? (tool === "edit" ? { newString: payload.content } : { content: payload.content }) : {}),
      ...(payload.command ? { command: payload.command } : {}),
      ...(payload.query ? { query: payload.query } : {}),
      ...(payload.url ? { url: payload.url } : {}),
    },
  }),
  pi: (toolName, payload, tool) => ({
    toolName,
    input: {
      ...(payload.filePath ? { path: payload.filePath } : {}),
      ...(payload.content
        ? tool === "edit"
          ? { edits: [{ newText: payload.content }] }
          : { content: payload.content }
        : {}),
      ...(payload.command ? { command: payload.command } : {}),
      ...(payload.query
        ? tool === "fff-grep"
          ? { pattern: payload.query }
          : { query: payload.query }
        : {}),
      ...(payload.url ? { url: payload.url } : {}),
    },
  }),
};

/**
 * Inverse of normalizeEvent: renders a canonical payload in one client's
 * dialect. The selfcheck canary and the cross-client parity test both need to
 * drive a real client-shaped event through the real normalizer; undefined means
 * the client has no spelling for that tool, i.e. the route does not exist.
 */
export function encodeEvent(
  client: ClientId | string,
  tool: ToolKind,
  payload: Partial<EventPayload>,
  registry: Registry,
): unknown | undefined {
  const profile = profileFor(registry, client);
  const writer = WRITERS[client as ClientId];
  if (!profile || !writer) return undefined;

  const toolName = Object.keys(profile.tools).find((name) => profile.tools[name] === tool);
  if (!toolName) return undefined;

  return writer(toolName, { ...emptyPayload(), ...payload }, tool);
}
