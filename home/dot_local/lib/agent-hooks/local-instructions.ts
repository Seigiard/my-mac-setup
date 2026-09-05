// Local private project instructions: selection, safety, and formatting.
//
// Shared by the Pi extension (~/.pi/agent/extensions/agents-local.ts) and the
// opencode plugin (~/.config/opencode/plugins/agents-local.ts) so the
// symlink-escape check, the size cap and the emitted block exist once (R7).
//
// Boundary (KTD11): this module sits in the agent-hooks lib root for
// deployment reasons only. It is not part of the tool-call dispatch core and
// imports nothing from it — no import edge exists in either direction, and the
// core's pure-and-synchronous policy invariant does not apply here: selection
// is async and reads the filesystem by design.

import { lstat, readFile, realpath, stat } from "node:fs/promises";
import { isAbsolute, join, relative } from "node:path";

export const LOCAL_INSTRUCTION_FILE_NAMES = ["AGENTS.local.md", "CLAUDE.local.md"] as const;
export const MAX_LOCAL_INSTRUCTIONS_BYTES = 50 * 1024;

// Emitted by formatLocalInstructions and read back by the opencode plugin as
// its idempotence guard, so the marker a consumer looks for is the marker the
// formatter actually writes.
export const LOCAL_INSTRUCTIONS_HEADING = "## Local Private Project Instructions";

export type LocalInstructionFileName = (typeof LOCAL_INSTRUCTION_FILE_NAMES)[number];

export type DiagnosticStatus =
  | "missing"
  | "candidate"
  | "selected"
  | "skipped-preferred-agents"
  | "skipped-not-file"
  | "skipped-broken-symlink"
  | "skipped-outside-project"
  | "skipped-too-large"
  | "skipped-unreadable";

export interface LocalInstructionDiagnostic {
  name: LocalInstructionFileName;
  path: string;
  realPath?: string;
  size?: number;
  status: DiagnosticStatus;
}

export interface LocalInstructionCandidate extends LocalInstructionDiagnostic {
  status: "candidate";
  realPath: string;
  size: number;
}

export interface LocalInstructionSelection {
  selected?: LocalInstructionCandidate;
  diagnostics: LocalInstructionDiagnostic[];
  warnings: string[];
}

export interface LocalInstructionsBlock {
  block?: string;
  warnings: string[];
}

function isMissing(error: unknown): boolean {
  const code = (error as NodeJS.ErrnoException | undefined)?.code;
  return code === "ENOENT" || code === "ENOTDIR";
}

function isWithinProject(projectRealPath: string, targetRealPath: string): boolean {
  const projectRelativePath = relative(projectRealPath, targetRealPath);
  return projectRelativePath === "" || (!projectRelativePath.startsWith("..") && !isAbsolute(projectRelativePath));
}

async function inspectCandidate(
  cwd: string,
  getCwdRealPath: () => Promise<string | undefined>,
  name: LocalInstructionFileName,
): Promise<{ diagnostic: LocalInstructionDiagnostic; warning?: string }> {
  const path = join(cwd, name);
  let linkStat;
  try {
    linkStat = await lstat(path);
  } catch (error) {
    if (isMissing(error)) {
      return {
        diagnostic: {
          name,
          path,
          status: "missing",
        },
      };
    }
    const warning = `Could not inspect ${path}; skipping local instructions from ${name}.`;
    return {
      diagnostic: {
        name,
        path,
        status: "skipped-unreadable",
      },
      warning,
    };
  }

  const isSymlink = linkStat.isSymbolicLink();
  let targetStat: Awaited<ReturnType<typeof stat>>;
  let targetRealPath: string;
  try {
    if (isSymlink) {
      [targetStat, targetRealPath] = await Promise.all([stat(path), realpath(path)]);
    } else {
      targetStat = linkStat;
      targetRealPath = await realpath(path);
    }
  } catch (error) {
    const status = isSymlink && isMissing(error) ? "skipped-broken-symlink" : "skipped-unreadable";
    const warning =
      status === "skipped-broken-symlink"
        ? `${path} is a broken symlink; skipping local instructions from ${name}.`
        : `Could not read ${path}; skipping local instructions from ${name}.`;
    return {
      diagnostic: {
        name,
        path,
        status,
      },
      warning,
    };
  }

  if (!targetStat.isFile()) {
    return {
      diagnostic: {
        name,
        path,
        realPath: targetRealPath,
        status: "skipped-not-file",
      },
    };
  }

  const cwdRealPath = await getCwdRealPath();
  if (cwdRealPath && !isWithinProject(cwdRealPath, targetRealPath)) {
    const warning = `${path} resolves outside the project to ${targetRealPath}; skipping local instructions from ${name}.`;
    return {
      diagnostic: {
        name,
        path,
        realPath: targetRealPath,
        size: targetStat.size,
        status: "skipped-outside-project",
      },
      warning,
    };
  }

  if (targetStat.size > MAX_LOCAL_INSTRUCTIONS_BYTES) {
    const warning = `${path} is ${targetStat.size} bytes, above the ${MAX_LOCAL_INSTRUCTIONS_BYTES} byte limit; skipping local instructions from ${name}.`;
    return {
      diagnostic: {
        name,
        path,
        realPath: targetRealPath,
        size: targetStat.size,
        status: "skipped-too-large",
      },
      warning,
    };
  }

  return {
    diagnostic: {
      name,
      path,
      realPath: targetRealPath,
      size: targetStat.size,
      status: "candidate",
    },
  };
}

function selectPreferredCandidate(candidates: LocalInstructionCandidate[]): LocalInstructionCandidate | undefined {
  return candidates.find((candidate) => candidate.name === "AGENTS.local.md") ?? candidates[0];
}

function markSelection(
  diagnostics: LocalInstructionDiagnostic[],
  selected?: LocalInstructionCandidate,
): LocalInstructionDiagnostic[] {
  if (!selected) return diagnostics;
  return diagnostics.map((diagnostic) => {
    if (diagnostic.status !== "candidate") return diagnostic;
    if (diagnostic.path === selected.path) {
      return { ...diagnostic, status: "selected" };
    }
    return {
      ...diagnostic,
      status: "skipped-preferred-agents",
    };
  });
}

export async function inspectLocalInstructions(cwd: string): Promise<LocalInstructionSelection> {
  let cwdRealPathPromise: Promise<string | undefined> | undefined;
  const getCwdRealPath = (): Promise<string | undefined> => {
    cwdRealPathPromise ??= realpath(cwd).catch(() => undefined);
    return cwdRealPathPromise;
  };

  const inspected = await Promise.all(
    LOCAL_INSTRUCTION_FILE_NAMES.map((name) => inspectCandidate(cwd, getCwdRealPath, name)),
  );
  const diagnostics = inspected.map(({ diagnostic }) => diagnostic);
  const warnings = inspected.flatMap(({ warning }) => (warning ? [warning] : []));
  const candidates = diagnostics.filter(
    (diagnostic): diagnostic is LocalInstructionCandidate => diagnostic.status === "candidate",
  );
  const selected = selectPreferredCandidate(candidates);

  return {
    selected,
    diagnostics: markSelection(diagnostics, selected),
    warnings,
  };
}

export function formatLocalInstructions(selected: LocalInstructionCandidate, contents: string): string {
  return `

${LOCAL_INSTRUCTIONS_HEADING}

Loaded from ${selected.realPath}. These instructions are private and local. Follow them in addition to repository instructions.

### ${selected.name}

${contents}`;
}

/**
 * Select, read and format in one call. Both clients go through this so their
 * emitted blocks are identical by construction rather than by two call sites
 * that happen to agree today.
 */
export async function buildLocalInstructions(cwd: string): Promise<LocalInstructionsBlock> {
  const selection = await inspectLocalInstructions(cwd);
  if (!selection.selected) return { warnings: selection.warnings };

  let contents;
  try {
    contents = await readFile(selection.selected.realPath, "utf8");
  } catch {
    return {
      warnings: [
        ...selection.warnings,
        `Could not read ${selection.selected.realPath}; skipping local instructions from ${selection.selected.name}.`,
      ],
    };
  }

  return {
    block: formatLocalInstructions(selection.selected, contents),
    warnings: selection.warnings,
  };
}
