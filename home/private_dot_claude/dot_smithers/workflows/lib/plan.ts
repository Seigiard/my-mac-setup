// Derive the work-gate validate command from a plan's Verification Contract
// (KTD8 revision): the plan is a trusted operator-authored input, so its
// declared, already-scoped verification commands are a safe default — unlike a
// command read from the target repo's own config, which KTD8 still forbids.
// --validate-cmd overrides this. Extraction is a heuristic; the pipeline logs
// the derived command so a wrong pick is visible and overridable.

// A command is kept only if it looks like a read-only verification runner.
// Keep signals match whole TOKENS, not substrings: run-1784823010502 derived
// `(test)` from a prose annotation ("script is `e2e`, not `test`") and kept a
// jq line because a FILENAME contained "withTests" — both always/never fail
// regardless of the work, poisoning the gate.
const KEEP_TOKENS = new Set(["test", "tests", "vitest", "jest", "pytest", "tsc", "typecheck", "check", "lint"]);
// A single-word span is prose unless the word alone is a runnable runner
// (bare `test` is the shell builtin, exit 1; bare `check`/`lint` are
// command-not-found; bare `vitest` is watch mode).
const STANDALONE_RUNNERS = new Set(["tsc", "pytest", "jest"]);
// Forbid: server/watch/e2e/visual runners (never terminate or need a
// browser/services) and mutating commands (fix/format would dirty the
// worktree and trip the work gate's clean-tree check).
const FORBID_SIGNALS = ["storybook", "--watch", ":watch", " dev", "serve", "start", "playwright", "e2e", "fix", "format", " vrt"];

// `- cmd`, `* cmd`, `+ cmd`, `1. cmd`, `1) cmd` — a markdown list marker plus a
// space. The trailing space matters: `--flag` and `-1` are not list markers.
const LIST_ITEM = /^([-*+]|\d+[.)])\s+/;

function backtickSpans(text: string): string[] {
  const spans: string[] = [];
  const re = /`([^`]+)`/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) spans.push(m[1].trim());
  return spans;
}

function isRunnableVerification(cmd: string): boolean {
  const lc = cmd.toLowerCase();
  const tokens = lc.split(/[^a-z0-9]+/).filter(Boolean);
  if (!tokens.some((t) => KEEP_TOKENS.has(t))) return false;
  if (FORBID_SIGNALS.some((s) => lc.includes(s))) return false;
  if (!/\s/.test(cmd.trim())) return STANDALONE_RUNNERS.has(lc.trim());
  return true;
}

// Returns the joined validate command, or null when the plan has no
// Verification Contract or no runnable commands in it.
export function extractValidateCmd(markdown: string): string | null {
  // The ce-plan section contract puts the heading at H2, but plans are
  // agent-authored markdown and the level drifts — one real plan nested the
  // contract at H3 under Planning Contract and gate-0 refused the run. Accept
  // any depth and end the section at the next heading of the same or
  // shallower depth, so a nested contract never swallows sibling sections
  // (a Sources glob line like `include: ['**/*.test.ts']` would pass the
  // token filter and be executed as a command).
  const heading = /^(#{2,6})\s+Verification Contract\s*$/m.exec(markdown);
  if (!heading) return null;
  const body = markdown.slice(heading.index + heading[0].length);
  const nextSection = body.search(new RegExp(`^#{1,${heading[1].length}}\\s+`, "m"));
  const section = nextSection === -1 ? body : body.slice(0, nextSection);

  const commands: string[] = [];
  const seen = new Set<string>();
  const keep = (cmd: string): void => {
    if (!isRunnableVerification(cmd)) return;
    if (seen.has(cmd)) return;
    seen.add(cmd);
    commands.push(cmd);
  };
  // Three shapes in the wild: table rows with backticked commands (fixture
  // plans), fenced shell blocks (ce-plan writes the contract as ```bash), and
  // bullet/ordered list items with inline backticks (hand-written plans). A
  // bare PARAGRAPH stays excluded on purpose: prose carries backticked
  // identifiers, and run-1784823010502 poisoned its gate by deriving `(test)`
  // from the sentence "script is `e2e`, not `test`".
  let inFence = false;
  let fenceIsShell = false;
  for (const line of section.split("\n")) {
    const trimmed = line.trim();
    const fence = trimmed.match(/^```(\w*)/);
    if (fence) {
      inFence = !inFence;
      fenceIsShell = inFence && ["", "bash", "sh", "shell", "zsh"].includes(fence[1].toLowerCase());
      continue;
    }
    if (inFence) {
      // Trailing comments are stripped BEFORE the filter — a "# transpile
      // check" annotation must not smuggle a keep-signal into a non-test line.
      const cmd = trimmed.replace(/\s+#.*$/, "");
      if (fenceIsShell && cmd !== "" && !cmd.startsWith("#")) keep(cmd);
      continue;
    }
    const isTableRow = trimmed.startsWith("|");
    const isListItem = LIST_ITEM.test(trimmed);
    if (!isTableRow && !isListItem) continue;
    if (isTableRow && /^\s*\|[\s|:-]+\|?\s*$/.test(line)) continue; // separator row
    for (const span of backtickSpans(line)) keep(span);
  }
  if (commands.length === 0) return null;
  // Each command in its own subshell so a leading `cd <pkg>` cannot leak into
  // the next command (the plan's rows are written repo-root-relative).
  return commands.map((c) => `(${c})`).join(" && ");
}
