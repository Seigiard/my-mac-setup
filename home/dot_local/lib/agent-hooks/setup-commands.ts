// Shell command recognition for the worktree setup gate.

const GATED_COMMANDS = new Set(["bun", "bunx", "make", "tsc", "turbo", "npm", "npx"]);

const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|[^\s;&|]*)\s*/;

type HereDocument = { delimiter: string; stripTabs: boolean };

type HereDocumentSkip = { end: number; completed: boolean };

function stripAssignments(input: string): string {
  let rest = input.trimStart();

  while (true) {
    const assignment = rest.match(ASSIGNMENT);

    if (assignment === null) return rest;

    rest = rest.slice(assignment[0].length);
  }
}

function hereDocumentAt(command: string, index: number): HereDocument | undefined {
  if (
    command[index] !== "<" ||
    command[index - 1] === "<" ||
    command[index + 1] !== "<" ||
    command[index + 2] === "<"
  ) return undefined;

  let cursor = index + 2;
  let stripTabs = false;

  if (command[cursor] === "-") {
    stripTabs = true;
    cursor += 1;
  }

  while (command[cursor] === " " || command[cursor] === "\t") cursor += 1;

  const quote = command[cursor] === "'" || command[cursor] === '"' ? command[cursor] : undefined;

  if (quote !== undefined) {
    const start = cursor + 1;
    const end = command.indexOf(quote, start);

    return end === -1 || end === start ? undefined : { delimiter: command.slice(start, end), stripTabs };
  }

  const start = cursor;

  while (cursor < command.length && !/\s/.test(command[cursor])) cursor += 1;

  return cursor === start ? undefined : { delimiter: command.slice(start, cursor), stripTabs };
}

function skipHereDocuments(
  command: string,
  start: number,
  documents: HereDocument[],
): HereDocumentSkip {
  let cursor = start;

  for (const document of documents) {
    while (cursor < command.length) {
      const lineEnd = command.indexOf("\n", cursor);

      if (lineEnd === -1) {
        const line = command.slice(cursor).replace(/\r$/, "");
        const comparable = document.stripTabs ? line.replace(/^\t+/, "") : line;

        return comparable === document.delimiter
          ? { end: command.length, completed: true }
          : { end: command.length, completed: false };
      }

      const line = command.slice(cursor, lineEnd).replace(/\r$/, "");
      const comparable = document.stripTabs ? line.replace(/^\t+/, "") : line;

      cursor = lineEnd + 1;

      if (comparable === document.delimiter) break;
    }
  }

  return { end: cursor, completed: true };
}

function plainSegments(command: string): string[] {
  return command
    .split(/[;&|\n]+/)
    .map((segment) => segment.trim())
    .filter((segment) => segment !== "");
}

/** Split shell operators without treating quoted, escaped, or here-doc text as commands. */
function shellSegments(command: string): string[] {
  const segments: string[] = [];
  const hereDocuments: HereDocument[] = [];
  let current = "";
  let quote: '"' | "'" | undefined;
  let escaped = false;
  let arithmeticDepth = 0;
  let unterminatedHereDocument = false;

  const push = (): void => {
    if (current.trim() !== "") segments.push(current.trim());
    current = "";
  };

  for (let index = 0; index < command.length; index += 1) {
    const character = command[index];

    if (quote === "'") {
      current += character;

      if (character === "'") quote = undefined;
      continue;
    }

    if (escaped) {
      current += character;
      escaped = false;
      continue;
    }

    if (character === "\\") {
      current += character;
      escaped = true;
      continue;
    }

    if (quote !== undefined) {
      current += character;

      if (character === quote) quote = undefined;
      continue;
    }

    if (character === "'" || character === '"') {
      current += character;
      quote = character;
      continue;
    }

    if (arithmeticDepth > 0) {
      current += character;

      if (character === "$" && command[index + 1] === "(" && command[index + 2] === "(") {
        current += "((";
        index += 2;
        arithmeticDepth += 1;
      } else if (character === ")" && command[index + 1] === ")") {
        current += ")";
        index += 1;
        arithmeticDepth -= 1;
      }

      continue;
    }

    if (character === "$" && command[index + 1] === "(" && command[index + 2] === "(") {
      current += "$((";
      index += 2;
      arithmeticDepth = 1;
      continue;
    }

    const hereDocument = hereDocumentAt(command, index);

    if (hereDocument !== undefined) hereDocuments.push(hereDocument);

    if (character === "\n") {
      current += character;

      if (hereDocuments.length > 0) {
        const skipped = skipHereDocuments(command, index + 1, hereDocuments);
        current += command.slice(index + 1, skipped.end);
        index = skipped.end - 1;
        unterminatedHereDocument ||= !skipped.completed;
        hereDocuments.length = 0;
      }

      push();

      continue;
    }

    if (character === ";" || character === "|" || character === "&") {
      // Redirections such as `&>` are part of the command, not separators.
      if (character === "&" && (command[index + 1] === ">" || command[index + 1] === "<")) {
        current += character;
        continue;
      }

      push();

      if (command[index + 1] === character || (character === "|" && command[index + 1] === "&")) index += 1;
      continue;
    }

    current += character;
  }

  if (quote !== undefined || escaped || arithmeticDepth > 0 || hereDocuments.length > 0 || unterminatedHereDocument) {
    return plainSegments(command);
  }

  push();

  return segments;
}

function startsWithGatedCommand(segment: string): boolean {
  const rest = stripAssignments(segment);
  const token = rest.match(/^[^\s;&|]+/)?.[0];

  if (token === undefined) return false;

  if (GATED_COMMANDS.has(token)) return true;

  if (!/^mise\s+(?:exec|x)\s+--\s+/.test(rest)) return false;

  return startsWithGatedCommand(rest.replace(/^mise\s+(?:exec|x)\s+--\s+/, ""));
}

function isRecoverySegment(segment: string): boolean {
  const rest = stripAssignments(segment);

  return /^mise\s+exec\s+--\s+make\s+setup(?:\s+(?:(?:\d+)?(?:>>?|<<)\s*(?:&\d+|[^\s;&|]+)?))*\s*$/.test(rest);
}

export function isSetupCommand(command: string): boolean {
  return [plainSegments(command), shellSegments(command)].some((segments) => segments.some(startsWithGatedCommand));
}

export function isRecoveryCommand(command: string): boolean {
  return [plainSegments(command), shellSegments(command)].every((segments) => {
    const gatedSegments = segments.filter(startsWithGatedCommand);

    return gatedSegments.length > 0 && gatedSegments.every(isRecoverySegment);
  });
}
