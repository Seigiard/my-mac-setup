// The single home for the shared event corpus: the core suite and the three
// adapter suites import these instead of keeping per-suite copies, so a dialect
// drift shows up everywhere at once.
//
// Each raw event is written in the wire shape the shipped adapters read, not
// generated from the normalizer, so it stays an independent statement of what a
// client sends.

import type { ClientId, EventPayload, ToolKind } from "./types.ts";

export type DialectFixture = {
  name: string;
  tool: ToolKind;
  payload: Partial<EventPayload>;
  /** Absent client = that client has no wire shape for this tool. */
  raw: Partial<Record<ClientId, unknown>>;
};

const TEST_FILE = "/repo/tests/example_test.sh";
const WRITE_BODY = "assert_file_not_exists /tmp/gone\n";
const EDIT_BODY = "expect(result).toBe(1);";
const MULTI_EDIT_BODY = "first replacement\nsecond replacement";
const COMMAND = "status=$? && exit $status";
const QUERY = "KnowledgeContextField console";
const URL = "https://example.com/docs";

export const DIALECT_FIXTURES: DialectFixture[] = [
  {
    // A full-file write carries its text only in `content`; a normalizer that
    // reads edit fields alone would let every Write past the content policies.
    name: "write with content only",
    tool: "write",
    payload: { filePath: TEST_FILE, content: WRITE_BODY },
    raw: {
      claude: { tool_name: "Write", tool_input: { file_path: TEST_FILE, content: WRITE_BODY } },
      opencode: { tool: "write", args: { filePath: TEST_FILE, content: WRITE_BODY } },
      pi: { toolName: "write", input: { path: TEST_FILE, content: WRITE_BODY } },
    },
  },
  {
    // opencode's edit tool has sent both filePath and file_path.
    name: "single edit replacement",
    tool: "edit",
    payload: { filePath: TEST_FILE, content: EDIT_BODY },
    raw: {
      claude: { tool_name: "Edit", tool_input: { file_path: TEST_FILE, new_string: EDIT_BODY } },
      opencode: { tool: "edit", args: { file_path: TEST_FILE, newString: EDIT_BODY } },
      pi: { toolName: "edit", input: { path: TEST_FILE, edits: [{ newText: EDIT_BODY }] } },
    },
  },
  {
    name: "multi-edit aggregation",
    tool: "edit",
    payload: { filePath: TEST_FILE, content: MULTI_EDIT_BODY },
    raw: {
      claude: {
        tool_name: "MultiEdit",
        tool_input: {
          file_path: TEST_FILE,
          edits: [{ new_string: "first replacement" }, { new_string: "second replacement" }],
        },
      },
      opencode: { tool: "edit", args: { filePath: TEST_FILE, newString: MULTI_EDIT_BODY } },
      pi: {
        toolName: "edit",
        input: {
          path: TEST_FILE,
          edits: [{ newText: "first replacement" }, { newText: "second replacement" }],
        },
      },
    },
  },
  {
    name: "bash command",
    tool: "bash",
    payload: { command: COMMAND },
    raw: {
      claude: { tool_name: "Bash", tool_input: { command: COMMAND } },
      opencode: { tool: "bash", args: { command: COMMAND } },
      pi: { toolName: "bash", input: { command: COMMAND } },
    },
  },
  {
    name: "fff grep query",
    tool: "fff-grep",
    payload: { query: QUERY },
    raw: {
      claude: { tool_name: "mcp__fff__grep", tool_input: { query: QUERY } },
    },
  },
  {
    name: "web fetch url",
    tool: "web-fetch",
    payload: { url: URL },
    raw: {
      claude: { tool_name: "WebFetch", tool_input: { url: URL } },
    },
  },
];

export function fixture(name: string): DialectFixture {
  const found = DIALECT_FIXTURES.find((candidate) => candidate.name === name);
  if (!found) throw new Error(`unknown fixture: ${name}`);
  return found;
}
