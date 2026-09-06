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

// --- per-policy calibration corpus (KTD3) -----------------------------------
//
// Translated from the two bashunit suites that predate the port
// (tests/bashunit/oracle_guard_test.sh, zsh_reserved_name_guard_test.sh, both
// retired with the engines they drove — the `// <suite> NNN` markers below name
// their case numbers, readable in git history) plus the two inline hook rules.
// The expected strings below are transcribed from the shipped engines' stdout,
// not generated from the policy modules, so the two sides of every comparison
// stay independent.
//
// The `<policy-name>:` prefix on every non-allow text is pinned, not incidental.
// Its consumer used to be the opencode guard plugins, which rethrew engine
// stdout only when it passed `startsWith("<policy-name>:")`; those plugins are
// gone. What reads the prefix now is the contract itself: R3 requires a policy
// to deny with the same prefixed reason in every client where its target tool
// exists, and R9's reason-contract test in tests/agent-hooks-core.test.ts
// asserts `decision.reason.startsWith(`${policy.name}:`)` for every
// block-capable policy in every client it is applicable to. Drop a prefix here
// and the corpus stops agreeing with the cross-client parity check that keeps
// one client from silently diverging. The rest of each text is prose for a
// human reader; only the prefix is machine-load-bearing.

export type PolicyFixture = {
  name: string;
  policy: string;
  tool: ToolKind;
  payload: Partial<EventPayload>;
  verdict: "allow" | "block" | "context";
  /** Exact decision text for a non-allow verdict. */
  text?: string;
};

const ZSH_READONLY_SENTENCE =
  "readonly. The assignment fails AND leaves $? at 1, so a following `exit $status` or `FINAL_EXIT:$status` marker reports a fabricated failure for a command that actually succeeded.";
const ZSH_TIED_SENTENCE =
  "to PATH and the positional parameters. Assigning it silently destroys them for the rest of the command.";
const ZSH_FIX_SENTENCE =
  'Fix: rename the variable — `rc`, `st`, `exit_code`, `dir`. Reading $status is legal zsh and is not blocked, only assignment is. If this assignment genuinely runs under bash rather than this zsh, add a "zsh-ok:" comment to the command and retry.';

function zshReason(lines: string[], readonlyNames: string, tiedNames: string): string {
  const parts = ["zsh-reserved-name-guard: this command assigns to a parameter zsh reserves:", ...lines];
  if (readonlyNames !== "") parts.push(`zsh makes ${readonlyNames} ${ZSH_READONLY_SENTENCE}`);
  if (tiedNames !== "") parts.push(`zsh ties ${tiedNames} ${ZSH_TIED_SENTENCE}`);
  parts.push(ZSH_FIX_SENTENCE);
  return parts.join("\n");
}

const FFF_BARE_QUERY = "KnowledgeContextField console";

export const WEBFETCH_HINT_TEXT =
  "Reminder: /markdown-new returns cleaner markdown for this URL, needs no API key, and handles JS-heavy pages that WebFetch renders as an empty shell. Keep WebFetch only if the skill already failed on this page or the content is plain HTML.";

export const POLICY_FIXTURES: PolicyFixture[] = [
  // zsh_reserved_name_guard_test.sh 001
  {
    name: "zsh/flags the status capture idiom",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: "make test-ubuntu; status=$?; print -- FINAL_EXIT:$status; exit $status" },
    verdict: "block",
    text: zshReason(
      ["  line 1: make test-ubuntu; status=$?; print -- FINAL_EXIT:$status; exit $status"],
      "status",
      "",
    ),
  },
  // zsh_reserved_name_guard_test.sh 002
  {
    name: "zsh/reading status is not an assignment",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: "print -- ALIAS_MERGE_UBUNTU_FINAL_EXIT:$status; sleep 30; exit $status" },
    verdict: "allow",
  },
  // zsh_reserved_name_guard_test.sh 003
  {
    name: "zsh/reserved name outside command position passes",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: 'rc=$?; echo "status=$rc"; gh run view --status=completed' },
    verdict: "allow",
  },
  // zsh_reserved_name_guard_test.sh 004
  {
    name: "zsh/heredoc body passes",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: {
      command: "cat > /tmp/probe.sh <<EOF\nmake check\nstatus=$?\nexit $status\nEOF",
    },
    verdict: "allow",
  },
  // zsh_reserved_name_guard_test.sh 005
  {
    name: "zsh/zsh-ok comment releases the command",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: 'bash -c "true; status=$?; exit $status"  # zsh-ok: bash -c body' },
    verdict: "allow",
  },
  // zsh_reserved_name_guard_test.sh 006
  {
    name: "zsh/empty input fails open",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: "" },
    verdict: "allow",
  },
  // zsh_reserved_name_guard_test.sh 007 — one fixture per name zsh rejects.
  {
    name: "zsh/blocks status",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: "status=1" },
    verdict: "block",
    text: zshReason(["  line 1: status=1"], "status", ""),
  },
  {
    name: "zsh/blocks ARGC",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: "ARGC=1" },
    verdict: "block",
    text: zshReason(["  line 1: ARGC=1"], "ARGC", ""),
  },
  {
    name: "zsh/blocks PPID",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: "PPID=1" },
    verdict: "block",
    text: zshReason(["  line 1: PPID=1"], "PPID", ""),
  },
  {
    name: "zsh/blocks HISTCMD",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: "HISTCMD=1" },
    verdict: "block",
    text: zshReason(["  line 1: HISTCMD=1"], "HISTCMD", ""),
  },
  {
    name: "zsh/blocks LINENO",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: "LINENO=1" },
    verdict: "block",
    text: zshReason(["  line 1: LINENO=1"], "LINENO", ""),
  },
  // zsh_reserved_name_guard_test.sh 008
  {
    name: "zsh/an ordinary name zsh accepts is not blocked",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: "make check; rc=$?; exit $rc" },
    verdict: "allow",
  },
  // zsh_reserved_name_guard_test.sh 009
  {
    name: "zsh/assigning path destroys PATH and is blocked",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: "path=/usr/bin; ls" },
    verdict: "block",
    text: zshReason(["  line 1: path=/usr/bin; ls"], "", "path"),
  },
  // Both conditional sentences at once, which no single bashunit case reaches.
  {
    name: "zsh/readonly and tied sentences compose",
    policy: "zsh-reserved-name-guard",
    tool: "bash",
    payload: { command: "path=/x\nstatus=1" },
    verdict: "block",
    text: zshReason(["  line 1: path=/x", "  line 2: status=1"], "status", "path"),
  },
  {
    name: "fff/multi-token bare query is denied",
    policy: "fff-grep-guard",
    tool: "fff-grep",
    payload: { query: FFF_BARE_QUERY },
    verdict: "block",
    text: `fff-grep-guard: fff grep matches ONE literal line, so the query '${FFF_BARE_QUERY}' will return "0 exact matches". Pick one: search a single identifier with this same fff grep tool; search several identifiers with your client's fff multi-grep tool and a JSON array of patterns; or use your client's built-in text search for a regex or a quoted phrase. Adding a path token such as 'console/' also passes this guard.`,
  },
  {
    name: "fff/single identifier passes",
    policy: "fff-grep-guard",
    tool: "fff-grep",
    payload: { query: "KnowledgeContextField" },
    verdict: "allow",
  },
  {
    name: "fff/path-scoped query passes",
    policy: "fff-grep-guard",
    tool: "fff-grep",
    payload: { query: "KnowledgeContextField console/" },
    verdict: "allow",
  },
  {
    name: "fff/glob query passes",
    policy: "fff-grep-guard",
    tool: "fff-grep",
    payload: { query: "KnowledgeContextField *.tsx" },
    verdict: "allow",
  },
  {
    name: "fff/absent query fails open",
    policy: "fff-grep-guard",
    tool: "fff-grep",
    payload: {},
    verdict: "allow",
  },
  {
    name: "webfetch/ordinary url gets the hint",
    policy: "webfetch-markdown-hint",
    tool: "web-fetch",
    payload: { url: "https://example.com/docs/guide" },
    verdict: "context",
    text: WEBFETCH_HINT_TEXT,
  },
  {
    name: "webfetch/a markdown.new url is left alone",
    policy: "webfetch-markdown-hint",
    tool: "web-fetch",
    payload: { url: "https://markdown.new/https://example.com/docs/guide" },
    verdict: "allow",
  },
  {
    name: "webfetch/absent url fails open",
    policy: "webfetch-markdown-hint",
    tool: "web-fetch",
    payload: {},
    verdict: "allow",
  },
];

export function policyFixtures(policy: string): PolicyFixture[] {
  return POLICY_FIXTURES.filter((candidate) => candidate.policy === policy);
}
