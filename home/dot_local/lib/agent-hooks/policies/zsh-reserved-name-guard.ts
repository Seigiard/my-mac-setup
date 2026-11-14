// Reserved-parameter gate for proposed shell commands.
//
// The adapter observes the shell that will run a tool call. Bash leaves these
// names free, but zsh reserves them: `status` is a readonly alias of `$?`,
// `path` and `argv` are tied to PATH and the positional parameters. The guard
// scans the command only when the observation is zsh or absent; a bash
// observation allows it without scanning. `cmd; status=$?; exit $status`
// otherwise does not merely print "read-only variable: status" — the failed
// assignment leaves `$?` at 1, and the `exit $status` that follows reports a
// fabricated failure for a command that succeeded. That silent wrong verdict,
// not the error line, is what this gate exists to stop.
//
// Reading `$status` is legal zsh and passes. An unknown shell is treated as zsh
// so an adapter that cannot observe its execution boundary does not weaken the
// gate.

import type { Decision, NormalizedEvent, Policy } from "../types.ts";
import { ALLOW, block } from "../types.ts";

const NAME = "zsh-reserved-name-guard";

/** Declares that the assignment runs under bash, not under this zsh. */
const ESCAPE_HATCH = "zsh-ok:";

const READONLY_NAMES = [
  "status",
  "options",
  "ARGC",
  "PPID",
  "HISTCMD",
  "LINENO",
  "TTYIDLE",
  "ZSH_SUBSHELL",
  "ZSH_EVAL_CONTEXT",
  "zsh_eval_context",
];

const TIED_NAMES = ["path", "argv"];

const RESERVED = new Set([...READONLY_NAMES, ...TIED_NAMES]);

/** Separators that start a new command, i.e. a new assignment position. */
const COMMAND_SEPARATORS = /[;&|(){}`]/g;

const DECLARATION_KEYWORDS =
  /^(local|typeset|declare|export|readonly|integer|float|if|then|else|elif|while|until|do)[ \t]+/;

const SHORT_OPTION = /^-[A-Za-z]+[ \t]+/;

const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=/;

const HEREDOC_START = /<<-?[ \t]*/;

const HEREDOC_DELIMITER = /^[^ \t;&|<>()]+/;

const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/;

const INERT_COMMANDS = new Set([
  "grep", "rg", "echo", "printf", "jq", "curl", "sed", "cd", "cat", "head",
  "tail", "wc", "sort", "uniq", "cut", "tr", "ls", "git", "gh",
]);

const LAUNCHERS = new Set([
  "zsh", "bash", "sh", "dash", "ksh", "eval", "source", ".", "exec", "env", "xargs",
  "sudo", "nohup", "timeout", "time", "command", "builtin", "hc", "hc-run", "herdr-run",
  "find", "parallel", "fd", "watch", "entr", "script", "ssh", "tmux", "osascript",
]);

const ASSIGNMENT_WORD = /^[A-Za-z_][A-Za-z0-9_]*=/;

const CONTROL_PREFIX =
  /(?:^[ \t]*|[;&|][ \t]*|[({][ \t]*|\b(?:while|until|do|then|else)[ \t]+|(?:[A-Za-z_][A-Za-z0-9_]*=(?:[^ \t;&|]*)?[ \t]+)+)/;

const LOOP_VARIABLE = new RegExp(
  `${CONTROL_PREFIX.source}(?:for|select)[ \t]+([A-Za-z_][A-Za-z0-9_]*)(?=[ \t]*(?:in\\b|;|$))`,
);

const READ_COMMAND = new RegExp(`${CONTROL_PREFIX.source}read\\b([^\n;&|]*)`);

/** Report width; a long one-liner is truncated the way the report is read. */
const MAX_SHOWN = 120;

const READONLY_SENTENCE =
  "readonly. The assignment fails AND leaves $? at 1, so a following `exit $status` or `FINAL_EXIT:$status` marker reports a fabricated failure for a command that actually succeeded.";

const TIED_SENTENCE =
  "to PATH and the positional parameters. Assigning it silently destroys them for the rest of the command.";

const FIX =
  'Fix: rename the variable — `rc`, `st`, `exit_code`, `dir`. Reading $status is legal zsh and is not blocked, only assignment is. If this assignment genuinely runs under bash rather than this zsh, add a "zsh-ok:" comment to the command and retry.';

type Hit = { name: string; text: string };

function heredocDelimiterOf(line: string): string {
  const start = line.match(HEREDOC_START);

  if (!start || start.index === undefined) return "";
  const rest = line.slice(start.index + start[0].length);
  const delimiter = rest.match(HEREDOC_DELIMITER);

  if (!delimiter) return "";
  const unquoted = delimiter[0].replace(/'/g, "").replace(/"/g, "");

  return IDENTIFIER.test(unquoted) ? unquoted : "";
}

function reservedNameIn(segment: string): string {
  let rest = segment.replace(/^[ \t]+/, "");

  while (DECLARATION_KEYWORDS.test(rest) || SHORT_OPTION.test(rest)) {
    rest = rest.replace(/^[^ \t]+[ \t]+/, "");
  }

  const assignment = rest.match(ASSIGNMENT);

  if (!assignment) return "";
  const name = assignment[0].replace(/(\[[^\]]*\])?\+?=$/, "");

  return RESERVED.has(name) ? name : "";
}

function loopOrReadName(line: string): string {
  const loop = line.match(LOOP_VARIABLE);

  if (loop !== null && RESERVED.has(loop[1])) return loop[1];

  const read = line.match(READ_COMMAND);

  if (read === null) return "";

  for (const token of read[1].trim().split(/[ \t]+/)) {
    if (token.startsWith("-")) continue;

    if (IDENTIFIER.test(token) && RESERVED.has(token)) return token;
  }

  return "";
}

function hits(command: string): Hit[] {
  const found: Hit[] = [];
  let heredoc = "";

  command.split("\n").forEach((line, index) => {
    if (heredoc !== "") {
      // A script written into a file runs under its own interpreter, not under
      // the zsh executing this command, so its assignments are not gated.
      if (line.replace(/^[ \t]+/, "").replace(/[ \t]+$/, "") === heredoc) heredoc = "";

      return;
    }

    const delimiter = heredocDelimiterOf(line);

    if (delimiter !== "") heredoc = delimiter;

    const stripped = line.replace(/^[ \t]+/, "");

    if (stripped.startsWith("#")) return;

    const controlName = loopOrReadName(line);

    if (controlName !== "") {
      const shown = stripped.length > MAX_SHOWN ? `${stripped.slice(0, MAX_SHOWN - 3)}...` : stripped;

      found.push({ name: controlName, text: `  line ${index + 1}: ${shown}` });

      return;
    }

    for (const segment of line.replace(COMMAND_SEPARATORS, "\n").split("\n")) {
      const name = reservedNameIn(segment);

      if (name === "") continue;

      const shown = stripped.length > MAX_SHOWN ? `${stripped.slice(0, MAX_SHOWN - 3)}...` : stripped;

      found.push({ name, text: `  line ${index + 1}: ${shown}` });
      break;
    }
  });

  return found;
}

/**
 * Return a masked copy only when the command fits the deliberately tiny
 * grammar. Unknown shell syntax falls back to the ordinary, unmasked scan.
 */
function maskInert(command: string): string | null {
  const out: string[] = [];
  let i = 0;

  while (i < command.length) {
    const c = command[i];
    const next = command[i + 1];

    if (c === "\\") {
      if (next === undefined) return null;
      out.push(c, next);
      i += 2;
      continue;
    }

    if (c === "'") {
      const close = command.indexOf("'", i + 1);

      if (close === -1) return null;
      out.push("'", ...Array.from(command.slice(i + 1, close), (part) => part === "\n" ? "\n" : "x"), "'");
      i = close + 1;
      continue;
    }

    if (c === '"') {
      const body: string[] = [];
      let j = i + 1;
      let closed = false;

      while (j < command.length) {
        const d = command[j];

        if (d === "\\") {
          if (command[j + 1] === undefined) return null;
          body.push("x", command[j + 1] === "\n" ? "\n" : "x");
          j += 2;
          continue;
        }

        if (d === "`") return null;

        if (d === "$" && ["(", "{", "["].includes(command[j + 1])) return null;

        if (d === '"') {
          closed = true;
          break;
        }

        body.push(d === "\n" ? "\n" : "x");
        j += 1;
      }

      if (!closed) return null;
      out.push('"', ...body, '"');
      i = j + 1;
      continue;
    }

    if (["`", "(", ")", "{", "}", "#"].includes(c)) return null;

    if (c === "$" && ["'", '"', "(", "{", "["].includes(next ?? "")) return null;

    if (c === "<" && next === "<") return null;

    out.push(c);
    i += 1;
  }

  const masked = out.join("");
  const flat = flattenQuotedNewlines(masked);

  return commandWordsAreInert(flat) ? masked : null;
}

function flattenQuotedNewlines(masked: string): string {
  let quote = "";
  let result = "";

  for (let i = 0; i < masked.length; i += 1) {
    const c = masked[i];

    if (quote === "") {
      if (c === "\\") {
        result += c + (masked[i + 1] ?? "");
        i += 1;
        continue;
      }

      if (c === "'" || c === '"') quote = c;
      result += c;
      continue;
    }

    if (c === quote) {
      quote = "";
      result += c;
      continue;
    }

    result += c === "\n" ? "x" : c;
  }

  return result;
}

function commandWordsAreInert(masked: string): boolean {
  for (const simple of masked.split(/\|\||&&|\|&|[;&|\n]/)) {
    const words = simple.trim().split(/[ \t]+/).filter((word) => word !== "");

    if (words.length === 0) continue;

    for (const word of words) {
      const bare = word.replace(/^["']|["']$/g, "");

      if (LAUNCHERS.has(bare)) return false;
    }

    let first = 0;

    while (first < words.length && ASSIGNMENT_WORD.test(words[first])) first += 1;

    if (first === words.length) continue;

    if (/^[<>]|^[0-9]+[<>]/.test(words[first])) return false;

    if (!INERT_COMMANDS.has(words[first])) return false;
  }

  return true;
}

function restoreOriginalLines(found: Hit[], original: string): Hit[] {
  const lines = original.split("\n");

  return found.map((hit) => {
    const lineNumber = hit.text.match(/^  line (\d+):/);

    if (lineNumber === null) return hit;

    const line = lines[Number(lineNumber[1]) - 1] ?? "";
    const stripped = line.replace(/^[ \t]+/, "");
    const shown = stripped.length > MAX_SHOWN ? `${stripped.slice(0, MAX_SHOWN - 3)}...` : stripped;

    return { ...hit, text: `  line ${lineNumber[1]}: ${shown}` };
  });
}

function isBash(shell: string | undefined): boolean {
  return shell === "bash" || shell?.endsWith("/bash") === true;
}

function evaluate(event: NormalizedEvent): Decision {
  const command = event.command;

  if (command === "" || command.includes(ESCAPE_HATCH)) return ALLOW;

  if (isBash(event.shell)) return ALLOW;

  const masked = maskInert(command);
  const found = restoreOriginalLines(hits(masked ?? command), command);

  if (found.length === 0) return ALLOW;

  const names = [...new Set(found.map((hit) => hit.name))].sort();
  const readonlyHits = names.filter((name) => READONLY_NAMES.includes(name));
  const tiedHits = names.filter((name) => TIED_NAMES.includes(name));

  const parts = [
    `${NAME}: this command assigns to a parameter zsh reserves:`,
    ...found.map((hit) => hit.text),
  ];

  if (readonlyHits.length > 0) parts.push(`zsh makes ${readonlyHits.join(" ")} ${READONLY_SENTENCE}`);

  if (tiedHits.length > 0) parts.push(`zsh ties ${tiedHits.join(" ")} ${TIED_SENTENCE}`);
  parts.push(FIX);

  return block(parts.join("\n"));
}

export const zshReservedNameGuard: Policy = {
  name: NAME,
  tools: ["bash"],
  outcomes: ["block"],
  escapeHatch: ESCAPE_HATCH,
  canary: { tool: "bash", payload: { command: "make check; status=$?; exit $status" } },
  evaluate,
};
