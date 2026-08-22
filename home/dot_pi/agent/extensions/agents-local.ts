import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { lstat, readFile, realpath, stat } from "node:fs/promises";
import { isAbsolute, join, relative } from "node:path";

export const LOCAL_INSTRUCTION_FILE_NAMES = ["AGENTS.local.md", "CLAUDE.local.md"] as const;
export const MAX_LOCAL_INSTRUCTIONS_BYTES = 50 * 1024;

type LocalInstructionFileName = (typeof LOCAL_INSTRUCTION_FILE_NAMES)[number];
type DiagnosticStatus =
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

const warnedKeys = new Set<string>();

function isMissing(error: unknown): boolean {
  const code = (error as NodeJS.ErrnoException | undefined)?.code;
  return code === "ENOENT" || code === "ENOTDIR";
}

function notifyWarningsOnce(ctx: ExtensionContext, warnings: string[]): void {
  if (!ctx.hasUI) return;
  for (const warning of warnings) {
    const key = `${ctx.cwd}:${warning}`;
    if (warnedKeys.has(key)) continue;
    warnedKeys.add(key);
    ctx.ui.notify(warning, "warning");
  }
}

function isWithinProject(projectRealPath: string, targetRealPath: string): boolean {
  const projectRelativePath = relative(projectRealPath, targetRealPath);
  return projectRelativePath === "" || (!projectRelativePath.startsWith("..") && !isAbsolute(projectRelativePath));
}

async function inspectCandidate(
  cwd: string,
  cwdRealPath: string | undefined,
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
  let targetStat;
  let targetRealPath;
  try {
    [targetStat, targetRealPath] = await Promise.all([stat(path), realpath(path)]);
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
  let cwdRealPath: string | undefined;
  try {
    cwdRealPath = await realpath(cwd);
  } catch {
    cwdRealPath = undefined;
  }

  const inspected = await Promise.all(
    LOCAL_INSTRUCTION_FILE_NAMES.map((name) => inspectCandidate(cwd, cwdRealPath, name)),
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

## Local Private Project Instructions

Loaded from ${selected.realPath}. These instructions are private and local. Follow them in addition to repository instructions.

### ${selected.name}

${contents}`;
}

export default function agentsLocalExtension(pi: ExtensionAPI): void {
  pi.on("before_agent_start", async (event, ctx) => {
    const selection = await inspectLocalInstructions(ctx.cwd);
    notifyWarningsOnce(ctx, selection.warnings);
    if (!selection.selected) return undefined;

    let contents;
    try {
      contents = await readFile(selection.selected.realPath, "utf8");
    } catch {
      const warning = `Could not read ${selection.selected.realPath}; skipping local instructions from ${selection.selected.name}.`;
      notifyWarningsOnce(ctx, [warning]);
      return undefined;
    }

    return {
      systemPrompt: event.systemPrompt + formatLocalInstructions(selection.selected, contents),
    };
  });
}
