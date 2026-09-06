// Reserved-parameter gate for proposed shell commands.
//
// Every agent runs its bash tool through the login shell, which is zsh on this
// machine, and herdr panes are zsh too. zsh reserves parameter names that bash
// leaves free: `status` is a readonly alias of `$?`, `path` and `argv` are tied
// to PATH and the positional parameters. So `cmd; status=$?; exit $status`
// does not merely print "read-only variable: status" — the failed assignment
// leaves `$?` at 1, and the `exit $status` that follows reports a fabricated
// failure for a command that succeeded. That silent wrong verdict, not the
// error line, is what this gate exists to stop.
//
// Only assignment is gated. Reading `$status` is legal zsh and passes.

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

function evaluate(event: NormalizedEvent): Decision {
  const command = event.command;
  if (command === "" || command.includes(ESCAPE_HATCH)) return ALLOW;

  const found = hits(command);
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
