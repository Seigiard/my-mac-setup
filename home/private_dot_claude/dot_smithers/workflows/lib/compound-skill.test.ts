import { afterAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { resolveCompoundSkill, stageCompoundSkill, type CompoundSkillPaths } from "./compound-skill.ts";

const tempDirs: string[] = [];
const SOURCE = "EveryInc/compound-engineering-plugin";

function tempDir(prefix: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

function fixture(): CompoundSkillPaths & { root: string } {
  const root = tempDir("compound-skill-");
  const canonicalRoot = path.join(root, "home/.agents/skills");
  const legacyRoot = path.join(root, "home/.claude/plugins/cache/compound-engineering-plugin/compound-engineering");
  const configRoot = path.join(root, "config/agent-skills");
  const lockPath = path.join(root, "state/skills/.skill-lock.json");
  fs.mkdirSync(canonicalRoot, { recursive: true });
  fs.mkdirSync(configRoot, { recursive: true });
  fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  return {
    root,
    canonicalRoot,
    legacyRoot,
    lockPath,
    cutoverReadyPath: path.join(configRoot, "cutover-ready"),
    cutoverGenerationPath: path.join(configRoot, "cutover-generation"),
  };
}

function writeSkill(root: string, name = "ce-code-review"): string {
  const dir = path.join(root, name);
  fs.mkdirSync(path.join(dir, "references"), { recursive: true });
  fs.writeFileSync(path.join(dir, "SKILL.md"), "# Skill\n");
  fs.writeFileSync(path.join(dir, "references", "nested.md"), "nested\n");
  return dir;
}

function writeLock(paths: CompoundSkillPaths, skills: Record<string, unknown>): void {
  fs.writeFileSync(paths.lockPath, JSON.stringify({ version: 3, skills }));
}

function matchingAttestation(paths: CompoundSkillPaths): void {
  const generation = `v1:${"a".repeat(64)}`;
  fs.writeFileSync(paths.cutoverGenerationPath, `${generation}\n`);
  fs.writeFileSync(paths.cutoverReadyPath, `${generation}\n`);
}

afterAll(() => {
  for (const dir of tempDirs) fs.rmSync(dir, { recursive: true, force: true });
});

describe("Compound Engineering skill resolution", () => {
  test("accepts only bare skill names", () => {
    const paths = fixture();

    expect(() => resolveCompoundSkill("../ce-code-review", paths)).toThrow(/bare skill name/i);
  });

  test("resolves and stages the complete canonical tree with its lock revision", () => {
    const paths = fixture();
    writeSkill(paths.canonicalRoot);
    writeLock(paths, { "ce-code-review": { source: SOURCE, skillFolderHash: "folder-hash" } });
    const stageDir = path.join(paths.root, "stage");

    const resolved = resolveCompoundSkill("ce-code-review", paths);
    const staged = stageCompoundSkill("ce-code-review", stageDir, paths);

    expect(resolved).toEqual({ dir: path.join(paths.canonicalRoot, "ce-code-review"), skillRevision: "folder-hash" });
    expect(staged).toEqual({ dir: stageDir, skillRevision: "folder-hash" });
    expect(fs.readFileSync(path.join(stageDir, "references", "nested.md"), "utf8")).toBe("nested\n");
  });

  test("accepts a canonical tree without a lock as explicitly untracked", () => {
    const paths = fixture();
    writeSkill(paths.canonicalRoot);

    expect(resolveCompoundSkill("ce-code-review", paths).skillRevision).toBe("untracked");
  });

  test("treats a valid lock with no matching skill as untracked", () => {
    const paths = fixture();
    writeSkill(paths.canonicalRoot);
    // Unit 1's lock contract requires source ownership for every entry; only
    // the requested Compound Engineering entry needs a revision hash.
    writeLock(paths, { unrelated: { source: "owner/repo" } });

    expect(resolveCompoundSkill("ce-code-review", paths).skillRevision).toBe("untracked");
  });

  test("fails closed when a canonical skill lacks SKILL.md", () => {
    const paths = fixture();
    fs.mkdirSync(path.join(paths.canonicalRoot, "ce-code-review"));

    expect(() => resolveCompoundSkill("ce-code-review", paths)).toThrow(/SKILL\.md/);
  });

  test("prefers a valid canonical skill over a legacy cache before cutover", () => {
    const paths = fixture();
    writeSkill(paths.canonicalRoot);
    writeSkill(path.join(paths.legacyRoot, "1.0.0", "skills"));

    expect(resolveCompoundSkill("ce-code-review", paths)).toEqual({
      dir: path.join(paths.canonicalRoot, "ce-code-review"),
      skillRevision: "untracked",
    });
  });

  test("uses the legacy cache only while attestation is absent, stale, or malformed", () => {
    const paths = fixture();
    const legacy = writeSkill(path.join(paths.legacyRoot, "1.0.0", "skills"));

    expect(resolveCompoundSkill("ce-code-review", paths)).toEqual({ dir: legacy, skillRevision: "legacy-plugin" });
    fs.writeFileSync(paths.cutoverGenerationPath, `v1:${"a".repeat(64)}\n`);
    fs.writeFileSync(paths.cutoverReadyPath, "not-an-attestation\n");
    expect(resolveCompoundSkill("ce-code-review", paths)).toEqual({ dir: legacy, skillRevision: "legacy-plugin" });
  });

  test("refuses the legacy cache after an exact attestation match", () => {
    const paths = fixture();
    writeSkill(path.join(paths.legacyRoot, "1.0.0", "skills"));
    matchingAttestation(paths);

    expect(() => resolveCompoundSkill("ce-code-review", paths)).toThrow(/canonical skill/i);
  });

  test("rejects symlinks and oversized files before staging", () => {
    const paths = fixture();
    const skill = writeSkill(paths.canonicalRoot);
    fs.symlinkSync("/etc/passwd", path.join(skill, "escape"));
    const stageDir = path.join(paths.root, "stage");

    expect(() => stageCompoundSkill("ce-code-review", stageDir, paths)).toThrow(/symlink/i);
    expect(fs.existsSync(stageDir)).toBe(false);

    fs.unlinkSync(path.join(skill, "escape"));
    fs.writeFileSync(path.join(skill, "large"), Buffer.alloc(10 * 1024 * 1024 + 1));
    expect(() => stageCompoundSkill("ce-code-review", stageDir, paths)).toThrow(/exceeds 10485760 bytes/);
    expect(fs.existsSync(stageDir)).toBe(false);
  });

  test("accepts files and a tree at the inclusive size limits", () => {
    const paths = fixture();
    const skill = path.join(paths.canonicalRoot, "ce-code-review");
    fs.mkdirSync(skill, { recursive: true });
    fs.writeFileSync(path.join(skill, "SKILL.md"), "x");
    for (let index = 0; index < 9; index++) fs.writeFileSync(path.join(skill, `part-${index}`), Buffer.alloc(10 * 1024 * 1024));
    fs.writeFileSync(path.join(skill, "part-final"), Buffer.alloc(10 * 1024 * 1024 - 1));

    expect(resolveCompoundSkill("ce-code-review", paths).skillRevision).toBe("untracked");
  });

  test("rejects malformed locks and source mismatches", () => {
    const paths = fixture();
    writeSkill(paths.canonicalRoot);
    fs.writeFileSync(paths.lockPath, "not json");
    expect(() => resolveCompoundSkill("ce-code-review", paths)).toThrow(/malformed or unsupported/i);

    writeLock(paths, { "ce-code-review": { source: "other/source", skillFolderHash: "hash" } });
    expect(() => resolveCompoundSkill("ce-code-review", paths)).toThrow(/source mismatch/i);
  });
});
