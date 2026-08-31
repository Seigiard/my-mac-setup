import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const COMPOUND_SOURCE = "EveryInc/compound-engineering-plugin";
const MAX_FILE_BYTES = 10 * 1024 * 1024;
const MAX_TREE_BYTES = 100 * 1024 * 1024;

export interface CompoundSkillPaths {
  canonicalRoot: string;
  legacyRoot: string;
  lockPath: string;
  cutoverReadyPath: string;
  cutoverGenerationPath: string;
}

export interface ResolvedCompoundSkill {
  dir: string;
  skillRevision: string;
}

interface LockEntry {
  source: string;
  skillFolderHash?: string;
}

type SkillLock = Map<string, LockEntry> | undefined;

export function defaultCompoundSkillPaths(home = os.homedir(), env = process.env): CompoundSkillPaths {
  const configHome = env.XDG_CONFIG_HOME || path.join(home, ".config");
  const stateHome = env.XDG_STATE_HOME || path.join(home, ".local/state");
  const lockPath = path.join(stateHome, "skills/.skill-lock.json");
  return {
    canonicalRoot: path.join(home, ".agents/skills"),
    legacyRoot: path.join(home, ".claude/plugins/cache/compound-engineering-plugin/compound-engineering"),
    lockPath,
    cutoverReadyPath: path.join(configHome, "agent-skills/cutover-ready"),
    cutoverGenerationPath: path.join(configHome, "agent-skills/cutover-generation"),
  };
}

export function resolveCompoundSkill(name: string, paths = defaultCompoundSkillPaths()): ResolvedCompoundSkill {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) throw new Error(`Invalid bare skill name: ${name}`);
  const lock = readLock(paths.lockPath);
  const canonicalDir = path.join(paths.canonicalRoot, name);
  if (fs.existsSync(canonicalDir)) {
    validateSkillTree(canonicalDir);
    const entry = lock?.get(name);
    if (entry === undefined) return { dir: canonicalDir, skillRevision: "untracked" };
    if (entry.source !== COMPOUND_SOURCE) {
      throw new Error(`Compound Engineering skill lock source mismatch for ${name}: ${entry.source}`);
    }
    if (entry.skillFolderHash === undefined) throw new Error(`Malformed or unsupported Skills CLI lock entry for ${name}`);
    return { dir: canonicalDir, skillRevision: entry.skillFolderHash };
  }

  if (hasCurrentAttestation(paths)) {
    throw new Error(`Canonical skill is missing after cutover: ${canonicalDir}`);
  }

  const legacyDir = resolveLegacySkillDir(name, paths.legacyRoot);
  validateSkillTree(legacyDir);
  return { dir: legacyDir, skillRevision: "legacy-plugin" };
}

export function stageCompoundSkill(name: string, destination: string, paths = defaultCompoundSkillPaths()): ResolvedCompoundSkill {
  const resolved = resolveCompoundSkill(name, paths);
  // Validate immediately before copy so an unsafe tree is never staged.
  validateSkillTree(resolved.dir);
  fs.cpSync(resolved.dir, destination, { recursive: true, errorOnExist: true });
  return { dir: destination, skillRevision: resolved.skillRevision };
}

function readLock(lockPath: string): SkillLock {
  if (!fs.existsSync(lockPath)) return undefined;
  let data: unknown;
  try {
    data = JSON.parse(fs.readFileSync(lockPath, "utf8"));
  } catch (err) {
    throw new Error(`Malformed or unsupported Skills CLI lock: ${errorMessage(err)}`);
  }
  if (!isRecord(data) || data.version !== 3 || !isRecord(data.skills)) {
    throw new Error("Malformed or unsupported Skills CLI lock");
  }

  const entries = new Map<string, LockEntry>();
  for (const [name, value] of Object.entries(data.skills)) {
    if (!isRecord(value) || typeof value.source !== "string" || (value.skillFolderHash !== undefined && typeof value.skillFolderHash !== "string")) {
      throw new Error("Malformed or unsupported Skills CLI lock");
    }
    entries.set(name, { source: value.source, skillFolderHash: value.skillFolderHash as string | undefined });
  }
  return entries;
}

function hasCurrentAttestation(paths: CompoundSkillPaths): boolean {
  const generation = readAttestation(paths.cutoverGenerationPath);
  const ready = readAttestation(paths.cutoverReadyPath);
  return generation !== undefined && generation === ready;
}

function readAttestation(filePath: string): string | undefined {
  try {
    const value = fs.readFileSync(filePath, "utf8");
    return /^v1:[0-9a-f]{64}\n?$/.test(value) ? value.trim() : undefined;
  } catch {
    return undefined;
  }
}

function resolveLegacySkillDir(name: string, legacyRoot: string): string {
  let versions: string[];
  try {
    versions = fs.readdirSync(legacyRoot).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  } catch {
    throw new Error(`Canonical skill is missing and no legacy plugin cache is available for ${name}`);
  }
  for (let index = versions.length - 1; index >= 0; index--) {
    const candidate = path.join(legacyRoot, versions[index], "skills", name);
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error(`Canonical skill is missing and no legacy plugin cache is available for ${name}`);
}

function validateSkillTree(root: string): void {
  let rootStats: fs.Stats;
  try {
    rootStats = fs.lstatSync(root);
  } catch {
    throw new Error(`Missing skill tree: ${root}`);
  }
  if (rootStats.isSymbolicLink() || !rootStats.isDirectory()) throw new Error(`Invalid skill tree root: ${root}`);
  if (!fs.lstatSync(path.join(root, "SKILL.md")).isFile()) throw new Error(`Skill tree is missing regular SKILL.md: ${root}`);

  let totalBytes = 0;
  const stack = [root];
  while (stack.length > 0) {
    const directory = stack.pop()!;
    for (const name of fs.readdirSync(directory)) {
      const item = path.join(directory, name);
      const stats = fs.lstatSync(item);
      if (stats.isSymbolicLink()) throw new Error(`Skill tree contains symlink: ${item}`);
      if (stats.isDirectory()) {
        stack.push(item);
        continue;
      }
      if (!stats.isFile()) throw new Error(`Skill tree contains non-regular entry: ${item}`);
      if (stats.size > MAX_FILE_BYTES) throw new Error(`Skill tree file exceeds ${MAX_FILE_BYTES} bytes: ${item}`);
      totalBytes += stats.size;
      if (totalBytes > MAX_TREE_BYTES) throw new Error(`Skill tree exceeds ${MAX_TREE_BYTES} bytes: ${root}`);
    }
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
