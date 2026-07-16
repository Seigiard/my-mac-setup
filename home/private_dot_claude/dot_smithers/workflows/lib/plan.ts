// Derive the work-gate validate command from a plan's Verification Contract
// (KTD8 revision): the plan is a trusted operator-authored input, so its
// declared, already-scoped verification commands are a safe default — unlike a
// command read from the target repo's own config, which KTD8 still forbids.
// --validate-cmd overrides this. Extraction is a heuristic; the pipeline logs
// the derived command so a wrong pick is visible and overridable.

// A command is kept only if it looks like a read-only verification runner...
const KEEP_SIGNALS = ["test", "vitest", "jest", "pytest", "typecheck", "tsc", "check", "lint"];
// ...and contains none of these: server/watch/e2e/visual runners (never
// terminate or need a browser/services) and mutating commands (fix/format
// would dirty the worktree and trip the work gate's clean-tree check).
const FORBID_SIGNALS = ["storybook", "--watch", ":watch", " dev", "serve", "start", "playwright", "e2e", "fix", "format", " vrt"];

function backtickSpans(text: string): string[] {
  const spans: string[] = [];
  const re = /`([^`]+)`/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) spans.push(m[1].trim());
  return spans;
}

function isRunnableVerification(cmd: string): boolean {
  const lc = cmd.toLowerCase();
  if (!KEEP_SIGNALS.some((s) => lc.includes(s))) return false;
  if (FORBID_SIGNALS.some((s) => lc.includes(s))) return false;
  return true;
}

// Returns the joined validate command, or null when the plan has no
// Verification Contract or no runnable commands in it.
export function extractValidateCmd(markdown: string): string | null {
  const header = markdown.search(/^##\s+Verification Contract\s*$/m);
  if (header === -1) return null;
  const rest = markdown.slice(header);
  const nextSection = rest.slice(1).search(/^##\s+/m);
  const section = nextSection === -1 ? rest : rest.slice(0, nextSection + 1);

  const commands: string[] = [];
  const seen = new Set<string>();
  const keep = (cmd: string): void => {
    if (!isRunnableVerification(cmd)) return;
    if (seen.has(cmd)) return;
    seen.add(cmd);
    commands.push(cmd);
  };
  // Two shapes in the wild: table rows with backticked commands (fixture
  // plans) and fenced shell blocks (ce-plan writes the contract as ```bash).
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
    if (!line.trimStart().startsWith("|")) continue; // table rows only
    if (/^\s*\|[\s|:-]+\|?\s*$/.test(line)) continue; // separator row
    for (const span of backtickSpans(line)) keep(span);
  }
  if (commands.length === 0) return null;
  // Each command in its own subshell so a leading `cd <pkg>` cannot leak into
  // the next command (the plan's rows are written repo-root-relative).
  return commands.map((c) => `(${c})`).join(" && ");
}
