// Derive the work-gate validate command from a plan (KTD8 revision): the plan
// is a trusted operator-authored input, so its declared, already-scoped
// verification commands are a safe default — unlike a command read from the
// target repo's own config, which KTD8 still forbids. --validate-cmd overrides
// this. The pipeline logs the derived command so a wrong pick is visible.
//
// Two shapes, in this order (issue 2026-08-14-014):
//   1. DECLARED — a `validate_commands:` YAML list in the plan's frontmatter.
//      The plan states its gate instead of being guessed at.
//   2. PARSED — the `Verification Contract` section, read by the prose parser
//      below. The fallback: it is what every plan already committed in a target
//      repo is written in, so no plan needs a migration.

import { splitSegments } from "./validate-probe.ts";

// The frontmatter key that carries the declaration. Named after the thing it
// produces — the operator already knows it as `--validate-cmd` and as the
// `work-gate validate-cmd [...]` log line — and spelled snake_case plural like
// its neighbours `artifact_readiness` / `execution`.
export const VALIDATE_COMMANDS_KEY = "validate_commands";

// The filter judges ONE WORD per shell segment: the runner, or the subcommand
// for a package-manager front-end. Issue 2026-08-14-010 killed the previous
// whole-line, bag-of-tokens version in both directions — it dropped
// `oxlint --deny-warnings src/a.ts` (no bare `lint` token), dropped
// `bun test tests/fixtures/plan.test.ts` (`fix` matched inside `fixtures`),
// kept `oxlint … src/a.test.ts` only because a FILENAME carried `test`, and
// admitted `oxfmt --write src` because mutation was guarded by tool NAME.
// Judging one word means a file path or a flag value can never decide the
// outcome, and each half of `bun test && oxfmt --write src` is judged alone.

// Runners whose job is verification. The set is explicit; the pattern below
// catches the rest by shape, applied to the runner word ONLY (`oxlint` matches
// `lint` there, `tests/fixtures/x.ts` never reaches it).
const VERIFICATION_RUNNERS = new Set([
  "tsc", "tsgo", "jest", "vitest", "pytest", "mocha", "ava", "eslint", "oxlint", "biome", "ruff", "mypy",
  "pyright", "phpstan", "clippy", "test", "tests", "typecheck", "types", "lint", "check", "validate", "verify", "ci",
]);
const VERIFICATION_NAME = /test|lint|check|typecheck|tsc|spec/;
// A single-word span is prose unless the word alone is a runnable runner
// (bare `test` is the shell builtin, exit 1; bare `check`/`lint` are
// command-not-found; bare `vitest` is watch mode).
const STANDALONE_RUNNERS = new Set(["tsc", "pytest", "jest"]);
// Front-ends whose first non-flag word is the meaningful name: the gate of
// `bun test`, `npm run test:unit` and `make lint` is `test`, `test:unit`, `lint`.
const FRONT_ENDS = new Set([
  "npm", "pnpm", "yarn", "bun", "bunx", "npx", "deno", "cargo", "go", "make", "just", "task",
  "mise", "poetry", "uv", "pipenv", "rye", "composer", "rake", "gradle", "mvn", "dotnet",
]);
const FRONT_END_PASS_THROUGH = new Set(["run", "run-script", "exec", "x", "dlx", "--"]);
// Front-end flags that consume the next word. `-w`/`--workspace` are listed
// here as well as in MUTATING_FLAGS: consumed as a front-end selector
// (`npm -w pkg run test`) the word is a package name, not "write in place".
const FRONT_END_FLAG_WITH_VALUE = new Set(["-w", "--workspace", "--filter", "-C", "--cwd", "--package", "--dir"]);
// Wrappers that prefix a real command. `timeout 120 bun run test` must be
// judged on `test`, not on `timeout`.
const WRAPPERS = new Set(["timeout", "env", "command", "nohup", "nice", "stdbuf", "xvfb-run"]);
const DURATION = /^\d+(\.\d+)?[smhd]?$/;
// Mutation is detected by FLAG, not by tool name: a name list always trails the
// next formatter, a flag list at least fails toward refusing. Matched as whole
// arguments, so `--fix` cannot fire on a path containing `fixtures`, and the
// negated/prefixed spellings (`--no-fix`, `--fix-dry-run`, `--fix-type`) do not
// match — `--fix-type` only works alongside a real `--fix`, which does.
const MUTATING_FLAGS = new Set(["--write", "-w", "--fix", "--in-place", "-i", "--apply", "--overwrite"]);
// Read-only flags let a formatter be a gate (`prettier --check .`). They never
// rescue a segment that also carries a mutating flag: `--write` mutates
// whatever else the line says.
const READ_ONLY_FLAGS = new Set(["--check", "--dry-run", "--list-different", "--no-write", "--no-fix", "--diff", "--verify"]);
// Names that mutate by profession. Kept from the pre-010 forbid list, but now
// matched against the runner/subcommand word instead of a raw substring of the
// whole line, so `bun run fix` is refused and `bun test tests/fixtures/…` is not.
const MUTATING_RUNNERS = new Set(["fix", "format", "fmt", "prettier", "oxfmt", "dprint", "black", "gofmt", "rustfmt", "isort", "autopep8"]);
// Server/watch/e2e/visual runners: they never terminate, or need a browser and
// live services a staged worktree does not have.
const ENVIRONMENT_RUNNERS = new Set(["storybook", "dev", "serve", "start", "watch", "playwright", "cypress", "e2e", "vrt"]);
const ENVIRONMENT_FLAGS = new Set(["--watch", "--serve", "--ui"]);
// Recognised, and recognised as NOT verification: lifecycle subcommands and
// data/inspection utilities. They do not disqualify a command (`bun install &&
// bun test` is a real gate) but they cannot carry one on their own — that is
// what keeps `cd pkg && bun build …` and the jq coverage line of
// run-1784823010502 out of the gate.
const NON_VERIFICATION_RUNNERS = new Set([
  "install", "add", "remove", "uninstall", "link", "unlink", "publish", "pack", "init", "create",
  "build", "bundle", "compile", "upgrade", "update", "outdated", "clean", "prepare",
  "jq", "echo", "cat", "ls", "head", "tail", "pwd", "open",
]);

// `- cmd`, `* cmd`, `+ cmd`, `1. cmd`, `1) cmd` — a markdown list marker plus a
// space. The trailing space matters: `--flag` and `-1` are not list markers.
const LIST_ITEM = /^([-*+]|\d+[.)])\s+/;

// "declared" — the plan's `validate_commands:` frontmatter list decided,
//              including when it decided to refuse.
// "parsed"   — the Verification Contract parser produced the command.
// "none"     — neither shape yielded one.
export type ValidateCmdSource = "declared" | "parsed" | "none";

export interface ValidateCmdDerivation {
  cmd: string | null;
  source: ValidateCmdSource;
  // Human-readable observations the operator should see even though the
  // command was kept — today: runners the filter did not recognise. Always
  // empty on the declared path: an unrecognised runner is not a finding when
  // the operator wrote the command down.
  notes: string[];
  dropped: Array<{ cmd: string; reason: string }>;
}

// Returns the joined validate command, where it came from, and everything the
// derivation observed. Nothing is dropped silently: a refused command appears
// in `dropped` with a reason, and a kept command with an unrecognised runner
// appears in `notes`.
export function deriveValidateCmd(markdown: string): ValidateCmdDerivation {
  const declaration = readDeclaredCommands(markdown);
  // A declaration decides on its own — a malformed one refuses instead of
  // falling back. Falling back would run a command the author did not write
  // while their typo goes unmentioned, which is the failure mode issue
  // 2026-08-14-014 exists to end.
  return declaration.present ? fromDeclaration(declaration) : fromVerificationContract(markdown);
}

// The plan's frontmatter block, or undefined when it has none. One definition
// so the list reader here and the single-value accessor in lib/gates.ts can
// never disagree about where the frontmatter ends.
export function planFrontmatter(markdown: string): string | undefined {
  return /^---\n([\s\S]*?)\n---/.exec(markdown)?.[1];
}

interface Declaration {
  present: boolean;
  commands: string[];
  // Set when the key is there but its value is not a usable list. The launch
  // is refused with this, never quietly reinterpreted.
  error?: { cmd: string; reason: string };
}

// The declared list is used VERBATIM: no keep-side filtering, because "does
// this runner look like a verification" is not the pipeline's guess to make
// once the operator wrote the list down (KTD8 already trusts the plan). The
// one refusal that survives is a mutating flag — see mutatingSegment.
function fromDeclaration(declaration: Declaration): ValidateCmdDerivation {
  if (declaration.error) return { cmd: null, source: "declared", notes: [], dropped: [declaration.error] };
  const dropped: Array<{ cmd: string; reason: string }> = [];
  for (const cmd of declaration.commands) {
    const mutating = mutatingSegment(cmd);
    if (mutating) dropped.push({ cmd, reason: `refused: segment \`${mutating.raw}\` ${mutating.reason} — the work gate runs the validate-cmd and then requires a clean worktree, so a command that rewrites files fails the stage for a reason unrelated to the work` });
  }
  // One refused entry refuses the whole declaration. Every entry of a declared
  // list is deliberate, so running the survivors would verify less than the
  // plan demands while the run still goes green — issue 2026-08-14-014's
  // central complaint. The prose parser drops instead, because there the
  // candidates are guesses.
  if (dropped.length > 0) return { cmd: null, source: "declared", notes: [], dropped };
  return { cmd: declaration.commands.map((c) => `(${c})`).join(" && "), source: "declared", notes: [], dropped };
}

// A mutating FLAG (`--write`, `--fix`, …) is refused on the declared path; a
// mutating NAME (`prettier`, `bun run fmt:check`) is not. A whole-argument flag
// is a fact about the command; a name is a guess, and `fmt:check` proves the
// guess is wrong often enough that it would block a correct declaration. A
// declared non-terminating command (`--watch`, storybook) is also left alone:
// the pre-work probe executes the validate-cmd once on the base commit, so it
// surfaces before a paid work leg and names itself as a timeout.
function mutatingSegment(cmd: string): SegmentVerdict | undefined {
  return splitSegments(cmd).map(judgeSegment).find((v) => v.refusal === "mutating-flag");
}

// Reads `validate_commands:` as a YAML block sequence. The frontmatter reader
// in lib/gates.ts is a line-prefix matcher returning one string — extending it
// to return a list would turn a four-line accessor into a mini-YAML parser for
// the sake of two callers that want a scalar, so the list parsing is scoped
// here instead and gates.ts keeps its accessor unchanged.
function readDeclaredCommands(markdown: string): Declaration {
  const frontmatter = planFrontmatter(markdown);
  if (frontmatter === undefined) return { present: false, commands: [] };
  const lines = frontmatter.split("\n");
  const keyIndex = lines.findIndex((line) => new RegExp(`^${VALIDATE_COMMANDS_KEY}\\s*:`).test(line));
  if (keyIndex === -1) return { present: false, commands: [] };

  const refuse = (reason: string): Declaration => ({ present: true, commands: [], error: { cmd: `${VALIDATE_COMMANDS_KEY}:`, reason } });
  const inline = lines[keyIndex].slice(lines[keyIndex].indexOf(":") + 1).trim();
  // A flow sequence (`[a, b]`) is refused rather than parsed: splitting it
  // would have to split on commas, and a real command carries commas.
  if (inline !== "" && !inline.startsWith("#")) {
    return refuse(`\`${VALIDATE_COMMANDS_KEY}: ${inline}\` is not a block list — write one command per \`- \` line under the key.`);
  }

  const commands: string[] = [];
  for (const line of lines.slice(keyIndex + 1)) {
    const trimmed = line.trim();
    if (trimmed === "" || trimmed.startsWith("#")) continue;
    // A YAML sequence entry is `-` plus whitespace, or a bare `-`. Anything
    // else — the next key, or a `-typo` that no YAML parser would accept as an
    // entry either — ends the sequence.
    const item = /^-(?:\s+(.*))?$/.exec(trimmed);
    if (!item) break;
    const value = scalar(item[1] ?? "");
    if (value === "") return refuse(`entry ${commands.length + 1} of ${VALIDATE_COMMANDS_KEY} is empty — every entry must be a command the work gate can run.`);
    commands.push(value);
  }
  if (commands.length === 0) {
    return refuse(`${VALIDATE_COMMANDS_KEY} is present but lists no command — declare at least one, or drop the key to fall back to the Verification Contract section.`);
  }
  return { present: true, commands };
}

// One YAML scalar: quoted content is taken as written (a command carries `#`
// and `&&`), an unquoted one loses its trailing ` # comment` the way YAML reads
// it.
function scalar(raw: string): string {
  const value = raw.trim();
  const quoted = /^(['"])([\s\S]*?)\1\s*(?:#.*)?$/.exec(value);
  return quoted ? quoted[2] : value.replace(/\s+#.*$/, "").trim();
}

function fromVerificationContract(markdown: string): ValidateCmdDerivation {
  const notes: string[] = [];
  const dropped: Array<{ cmd: string; reason: string }> = [];
  // The ce-plan section contract puts the heading at H2, but plans are
  // agent-authored markdown and the level drifts — one real plan nested the
  // contract at H3 under Planning Contract and gate-0 refused the run. Accept
  // any depth and end the section at the next heading of the same or
  // shallower depth, so a nested contract never swallows sibling sections
  // (a Sources glob line like `include: ['**/*.test.ts']` would pass the
  // token filter and be executed as a command).
  const heading = /^(#{2,6})\s+Verification Contract\s*$/m.exec(markdown);
  if (!heading) return { cmd: null, source: "none", notes, dropped };
  const body = markdown.slice(heading.index + heading[0].length);
  const nextSection = body.search(new RegExp(`^#{1,${heading[1].length}}\\s+`, "m"));
  const section = nextSection === -1 ? body : body.slice(0, nextSection);

  const commands: string[] = [];
  const seen = new Set<string>();
  const keep = (cmd: string): void => {
    if (seen.has(cmd)) return;
    seen.add(cmd);
    const verdict = judgeCommand(cmd);
    if (!verdict.kept) {
      dropped.push({ cmd, reason: verdict.reason });
      return;
    }
    notes.push(...verdict.notes);
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
  if (commands.length === 0) return { cmd: null, source: "none", notes, dropped };
  // Each command in its own subshell so a leading `cd <pkg>` cannot leak into
  // the next command (the plan's rows are written repo-root-relative).
  return { cmd: commands.map((c) => `(${c})`).join(" && "), source: "parsed", notes, dropped };
}

// What gate 0 tells an operator whose plan yielded no command. It names BOTH
// accepted shapes, with an example of the declaration: a refusal that does not
// say what was looked for is what issue 2026-08-14-014 was filed about, and it
// is the one thing an operator staring at a refused launch cannot look up
// faster than the message can say it. `observations` are the derivation's
// dropped/notes lines, so the message also says what it refused and why.
export function noValidateCmdRefusal(observations: string[]): string {
  const why = observations.length > 0 ? ` What it refused: ${observations.join("; ")}.` : "";
  return [
    `no --validate-cmd given and the plan yields no runnable verification command.${why}`,
    "Two shapes are accepted, in this order:",
    `  1. a \`${VALIDATE_COMMANDS_KEY}:\` YAML list in the plan's frontmatter — the declaration, used verbatim, e.g.`,
    `       ${VALIDATE_COMMANDS_KEY}:`,
    "         - cd engine/api && bun run typecheck",
    "         - bun run test:unit",
    "  2. a `Verification Contract` section (`##` through `######`) whose table rows, ```bash fenced lines, or `-`/`*`/`1.` list items carry backticked commands — the fallback parser, which keeps only runnable check/test/typecheck commands and refuses mutating, server, watch and e2e ones.",
    "Declare the commands in the plan's frontmatter, or pass --validate-cmd explicitly.",
  ].join("\n");
}

// Returns the joined validate command, or null when the plan declares none and
// its Verification Contract yields none. The terse accessor for
// a caller that wants only the command: gate 0 uses deriveValidateCmd instead,
// because what the derivation refused is exactly what issue 2026-08-14-010 says
// must never be silent.
export function extractValidateCmd(markdown: string): string | null {
  return deriveValidateCmd(markdown).cmd;
}

type CommandVerdict = { kept: true; notes: string[] } | { kept: false; reason: string };

// A command is kept when every one of its shell segments is acceptable AND at
// least one segment could be a verification. An unrecognised runner counts as
// "could be": dropping it silently is how the lint gate of run-1784823010502
// nearly vanished, so it is kept and named in the notes instead.
function judgeCommand(cmd: string): CommandVerdict {
  const verdicts = splitSegments(cmd).map(judgeSegment);
  const refused = verdicts.find((v) => v.kind === "refused");
  if (refused !== undefined) return { kept: false, reason: `refused: segment \`${refused.raw}\` ${refused.reason}` };
  const carriers = verdicts.filter((v) => v.kind === "verification" || v.kind === "unrecognised");
  if (carriers.length === 0) {
    const named = verdicts.map((v) => `\`${v.runner}\``).join(", ");
    const bare = verdicts.every((v) => v.kind === "bare");
    return {
      kept: false,
      reason: bare
        ? `no verification: ${named} is a single bare word, not a runnable command`
        : `no verification: none of its runners (${named === "" ? "none" : named}) runs a verification`,
    };
  }
  const notes = carriers
    .filter((v) => v.kind === "unrecognised")
    .map((v) => `unrecognised runner \`${v.runner}\` in \`${cmd}\` — kept, because dropping it would hide a real gate; the work gate will run it`);
  return { kept: true, notes };
}

// "neutral"  — `cd <path>`, an empty segment: neither verification nor violation
//              (`cd pkg && bun test` is the documented, deliberate shape).
// "bare"     — a lone word that is not a runnable runner: prose, not a command.
// "non-verification" — recognised, and recognised as not a gate (`install`, `jq`).
// "refused"  — mutating or non-terminating: disqualifies the whole command.
type SegmentKind = "neutral" | "bare" | "non-verification" | "verification" | "unrecognised" | "refused";

// Which rule refused, as data rather than as prose in `reason`: the declared
// path keeps only the flag-detected mutation and needs to tell it apart from
// the name-detected one without matching on a message string.
type RefusalCause = "" | "mutating-flag" | "mutating-name" | "environment-flag" | "environment-name";

interface SegmentVerdict {
  kind: SegmentKind;
  raw: string;
  runner: string;
  reason: string;
  refusal: RefusalCause;
}

function judgeSegment(raw: string): SegmentVerdict {
  const args = tokenize(raw);
  const verdict = (kind: SegmentKind, runner: string, reason = ""): SegmentVerdict => ({ kind, raw, runner, reason, refusal: "" });
  const refuse = (runner: string, refusal: RefusalCause, reason: string): SegmentVerdict => ({ kind: "refused", raw, runner, reason, refusal });

  let head = 0;
  while (head < args.length && (/^[A-Za-z_][A-Za-z0-9_]*=/.test(args[head]) || WRAPPERS.has(basename(args[head])))) {
    const isWrapper = WRAPPERS.has(basename(args[head]));
    head++;
    // A wrapper's own options and `timeout`'s duration belong to the wrapper.
    while (isWrapper && head < args.length && (args[head].startsWith("-") || DURATION.test(args[head]) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(args[head]))) head++;
  }
  if (head >= args.length) return verdict("neutral", "");

  const runner = basename(args[head]).toLowerCase();
  if (runner === "cd") return verdict("neutral", runner);

  let nameIndex = head;
  if (FRONT_ENDS.has(runner)) nameIndex = frontEndNameIndex(args, head);
  const name = nameIndex < args.length ? basename(args[nameIndex]).toLowerCase() : runner;
  const rest = args.slice(nameIndex + 1);
  const parts = name.split(/[^a-z0-9]+/).filter(Boolean);

  const mutating = rest.find((a) => MUTATING_FLAGS.has(a));
  if (mutating !== undefined) return refuse(name, "mutating-flag", `carries the mutating flag \`${mutating}\``);
  const environment = rest.find((a) => ENVIRONMENT_FLAGS.has(a));
  if (environment !== undefined) return refuse(name, "environment-flag", `carries \`${environment}\`, which never terminates`);
  const environmentWord = parts.find((p) => ENVIRONMENT_RUNNERS.has(p));
  if (environmentWord !== undefined) return refuse(name, "environment-name", `runs \`${environmentWord}\`, a server/watch/e2e runner`);

  const readOnly = rest.some((a) => READ_ONLY_FLAGS.has(a));
  const mutatingName = MUTATING_RUNNERS.has(name) || parts.some((p) => MUTATING_RUNNERS.has(p));
  if (mutatingName && !readOnly) return refuse(name, "mutating-name", `runs \`${name}\`, which rewrites files (no read-only flag on the segment)`);
  if (mutatingName) return verdict("verification", name);

  if (args.length === 1) return verdict(STANDALONE_RUNNERS.has(name) ? "verification" : "bare", name);
  if (VERIFICATION_RUNNERS.has(name) || VERIFICATION_NAME.test(name)) return verdict("verification", name);
  if (NON_VERIFICATION_RUNNERS.has(name)) return verdict("non-verification", name);
  return verdict("unrecognised", name);
}

// The meaningful word after a package-manager front-end: skip `run`/`exec`,
// the front-end's own flags, and workspace selectors that consume a value.
function frontEndNameIndex(args: string[], head: number): number {
  let i = head + 1;
  while (i < args.length) {
    const arg = args[i];
    if (FRONT_END_PASS_THROUGH.has(arg)) {
      i++;
      continue;
    }
    if (FRONT_END_FLAG_WITH_VALUE.has(arg)) {
      i += 2;
      continue;
    }
    if (arg.startsWith("-") || /^[A-Za-z_][A-Za-z0-9_]*=/.test(arg)) {
      i++;
      continue;
    }
    return i;
  }
  return head;
}

// Quote-aware argument split. Quotes are removed so a quoted argument is one
// token and its content can never be read as a flag.
function tokenize(segment: string): string[] {
  const args: string[] = [];
  let current = "";
  let started = false;
  const push = (): void => {
    if (started) args.push(current);
    current = "";
    started = false;
  };
  for (let i = 0; i < segment.length; i++) {
    const ch = segment[i];
    if (ch === "'" || ch === '"') {
      const end = segment.indexOf(ch, i + 1);
      const stop = end === -1 ? segment.length : end;
      current += segment.slice(i + 1, stop);
      started = true;
      i = stop;
      continue;
    }
    if (ch === "\\" && i + 1 < segment.length) {
      current += segment[i + 1];
      started = true;
      i++;
      continue;
    }
    if (/\s/.test(ch)) {
      push();
      continue;
    }
    current += ch;
    started = true;
  }
  push();
  return args;
}

function basename(word: string): string {
  const parts = word.split("/");
  return parts[parts.length - 1] === "" ? word : parts[parts.length - 1];
}

function backtickSpans(text: string): string[] {
  const spans: string[] = [];
  const re = /`([^`]+)`/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) spans.push(m[1].trim());
  return spans;
}
