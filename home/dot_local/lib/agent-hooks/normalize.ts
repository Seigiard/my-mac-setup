// The three client arg dialects, in and out.
//
// Field names come from the shipped adapters, which are the authority on what
// each client actually sends:
//   claude   tool_input.content / file_path / new_string / edits[].new_string
//   opencode args.content / filePath | file_path / newString
//   pi       input.content / path / edits[].newText / command | cmd / query | pattern
// Content is aggregated across the full-content and edit fields alike: a Write
// call carries its text only in `content`, and dropping it would let full-file
// writes past every content policy.

import { profileFor, toolKindFor } from "./registry.ts";
import { z } from "zod";
import type {
  ClientId,
  EventPayload,
  NormalizedEvent,
  Registry,
  ToolKind,
  ToolEventValue,
  ToolArguments,
  EncodedEvent,
} from "./types.ts";
import { emptyPayload } from "./types.ts";

const text = z.string().catch("");

const edit = z.object({ new_string: text, newText: text }).catch({ new_string: "", newText: "" });

const argumentsSchema = z.object({
  file_path: text, filePath: text, path: text,
  content: text, new_string: text, newString: text,
  edits: z.array(edit).catch([]),
  command: text, cmd: text, query: text, pattern: text, url: text,
});

const argumentsWithFallback = argumentsSchema.catch(() => argumentsSchema.parse({}));

const eventSchema = z.object({
  tool_name: text, tool: text, toolName: text,
  tool_input: argumentsWithFallback, args: argumentsWithFallback, input: argumentsWithFallback,
});

type ParsedEvent = z.infer<typeof eventSchema>;

function joinParts(parts: string[]): string {
  return parts.filter((part) => part !== "").join("\n");
}

type RawRead = { clientToolName: string; payload: EventPayload };

function readClaude(raw: ParsedEvent): RawRead {
  const input = raw.tool_input;

  return {
    clientToolName: raw.tool_name,
    payload: {
      filePath: input.file_path,
      content: joinParts([input.content, input.new_string, ...input.edits.map((edit) => edit.new_string)]),
      command: input.command,
      query: input.query,
      url: input.url,
    },
  };
}

function readOpencode(raw: ParsedEvent): RawRead {
  const args = raw.args;

  return {
    clientToolName: raw.tool,
    payload: {
      filePath: args.filePath || args.file_path,
      content: joinParts([args.content, args.newString]),
      command: args.command,
      query: args.query,
      url: args.url,
    },
  };
}

function readPi(raw: ParsedEvent): RawRead {
  const input = raw.input;
  const clientToolName = raw.toolName;

  return {
    clientToolName,
    payload: {
      filePath: input.path,
      content: joinParts([input.content, ...input.edits.map((edit) => edit.newText)]),
      command: input.command || input.cmd,
      query: clientToolName === "ffgrep" ? input.pattern : input.query,
      url: input.url,
    },
  };
}

const READERS: Record<ClientId, (raw: ParsedEvent) => RawRead> = {
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
  raw: ToolEventValue,
  registry: Registry,
): NormalizedEvent | undefined {
  const profile = profileFor(registry, client);

  if (!profile) return undefined;
  const reader = READERS[profile.client];

  let read: RawRead;

  try {
    const parsed = eventSchema.safeParse(raw);

    if (!parsed.success) return undefined;
    read = reader(parsed.data);
  } catch {
    return undefined;
  }

  const tool = toolKindFor(profile, read.clientToolName);

  if (!tool) return undefined;

  return { client: profile.client, clientToolName: read.clientToolName, tool, ...read.payload };
}

type Writer = (toolName: string, payload: EventPayload, tool: ToolKind) => EncodedEvent;

const WRITERS: Record<ClientId, Writer> = {
  claude: (toolName, payload, tool) => {
    const input = commonArguments(payload);

    if (payload.filePath) input.file_path = payload.filePath;

    if (payload.content) {
      if (tool === "edit") input.new_string = payload.content;
      else input.content = payload.content;
    }

    return { tool_name: toolName, tool_input: input };
  },
  opencode: (toolName, payload, tool) => {
    const args = commonArguments(payload);

    if (payload.filePath) args.filePath = payload.filePath;

    if (payload.content) {
      if (tool === "edit") args.newString = payload.content;
      else args.content = payload.content;
    }

    return { tool: toolName, args };
  },
  pi: (toolName, payload, tool) => {
    const input = commonArguments(payload);

    if (payload.filePath) input.path = payload.filePath;

    if (payload.content) {
      if (tool === "edit") input.edits = [{ newText: payload.content }];
      else input.content = payload.content;
    }

    if (payload.query && tool === "fff-grep") {
      delete input.query;
      input.pattern = payload.query;
    }

    return { toolName, input };
  },
};

function commonArguments(payload: EventPayload): ToolArguments {
  const input: ToolArguments = {};

  if (payload.command) input.command = payload.command;

  if (payload.query) input.query = payload.query;

  if (payload.url) input.url = payload.url;

  return input;
}

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
): EncodedEvent | undefined {
  const profile = profileFor(registry, client);

  if (!profile) return undefined;
  const writer = WRITERS[profile.client];

  const toolName = Object.keys(profile.tools).find((name) => profile.tools[name] === tool);

  if (!toolName) return undefined;

  return writer(toolName, { ...emptyPayload(), ...payload }, tool);
}
