import { afterEach, describe, expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { mkdir, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// This suite is deliberately separate from tests/agent-hooks-opencode-adapter.test.ts.
// agents-local is system-prompt injection, not tool-call dispatch: it shares
// the lib root with the core for deployment reasons only, and scenario 5 below
// pins that there is no import edge between them (KTD11). Folding these cases
// into the dispatch adapter's suite would blur the boundary this unit exists
// to draw.

const PLUGIN_PATH =
  process.env.AGENTS_LOCAL_OPENCODE_PLUGIN_PATH ??
  join(import.meta.dir, "../home/private_dot_config/opencode/plugins/agents-local.ts");
const PI_EXTENSION_PATH =
  process.env.PI_AGENTS_LOCAL_EXTENSION_PATH ?? join(import.meta.dir, "../home/dot_pi/agent/extensions/agents-local.ts");
const CORE_DIR = process.env.AGENT_HOOKS_CORE_PATH ?? join(import.meta.dir, "../home/dot_local/lib/agent-hooks");

const shared: any = await import(join(CORE_DIR, "local-instructions.ts"));

const temporaryPaths: string[] = [];
let loadCount = 0;

function temporaryDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  temporaryPaths.push(dir);
  return dir;
}

afterEach(() => {
  for (const path of temporaryPaths.splice(0)) rmSync(path, { recursive: true, force: true });
});

// --- fake opencode plugin host ----------------------------------------------
//
// Both consumers resolve the shared module once from $HOME at module scope, so
// each load gets its own home and its own copy of the file: bun would
// otherwise hand back the cached module and every later load would silently
// reuse the first one's resolution.

async function loadUnderHome(sourcePath: string, prefix: string): Promise<any> {
  const home = temporaryDir(`${prefix}-home-`);
  mkdirSync(join(home, ".local", "lib"), { recursive: true });
  symlinkSync(CORE_DIR, join(home, ".local", "lib", "agent-hooks"));

  const copy = join(temporaryDir(`${prefix}-copy-`), `${prefix}-${loadCount++}.ts`);
  cpSync(sourcePath, copy);

  const previousHome = process.env.HOME;
  process.env.HOME = home;
  try {
    return await import(copy);
  } finally {
    process.env.HOME = previousHome;
  }
}

type Hook = (input: unknown, output: { system: string[] }) => Promise<void>;

async function loadTransform(directory: string): Promise<Hook> {
  const module: any = await loadUnderHome(PLUGIN_PATH, "agents-local-opencode");
  const hooks = (await module.AgentsLocalPlugin({ directory, worktree: directory })) ?? {};
  const transform = hooks["experimental.chat.system.transform"];
  expect(transform).toBeTypeOf("function");
  return transform;
}

async function loadPiHandler(): Promise<Function> {
  const module: any = await loadUnderHome(PI_EXTENSION_PATH, "agents-local-pi");
  const handlers: Record<string, Function> = {};
  module.default({ on: (event: string, handler: Function) => (handlers[event] = handler) });
  return handlers.before_agent_start;
}

const BASE_SYSTEM = "You are opencode.";

async function projectWithAgentsLocal(contents: string): Promise<string> {
  const root = temporaryDir("agents-local-project-");
  await writeFile(join(root, "AGENTS.local.md"), contents);
  return root;
}

// --- scenario 1: shared-module parity ---------------------------------------

describe("shared selection module (R7)", () => {
  test("pi and opencode emit a byte-identical block for the same tree", async () => {
    // #given one project tree and both consumers pointed at it
    const root = await projectWithAgentsLocal("Shared fixture SENTINEL_PARITY_5e1a.\n");
    const transform = await loadTransform(root);
    const piHandler = await loadPiHandler();

    // #when each client injects
    const system = [BASE_SYSTEM];
    await transform({}, { system });
    const piResult = await piHandler({ systemPrompt: BASE_SYSTEM }, { cwd: root, hasUI: false });

    // #then the appended text is the same bytes on both sides
    expect(system).toHaveLength(2);
    expect(piResult.systemPrompt.slice(BASE_SYSTEM.length)).toBe(system[1]);
    expect(system[1]).toContain("SENTINEL_PARITY_5e1a");
  });
});

// --- scenario 2: the safety checks reach opencode ----------------------------

describe("selection safety in opencode (R7)", () => {
  test("a symlink escaping the project root is skipped and the in-project file wins", async () => {
    // #given AGENTS.local.md pointing outside the project, CLAUDE.local.md inside it
    const root = temporaryDir("agents-local-escape-");
    const outside = temporaryDir("agents-local-outside-");
    const outsideFile = join(outside, "outside.md");
    await writeFile(outsideFile, "OUTSIDE_SENTINEL_c40b must never be injected.\n");
    await symlink(outsideFile, join(root, "AGENTS.local.md"));
    await writeFile(join(root, "CLAUDE.local.md"), "In-project fallback INSIDE_SENTINEL_9d3f.\n");
    const transform = await loadTransform(root);

    // #when the transform runs
    const system = [BASE_SYSTEM];
    await transform({}, { system });

    // #then only the in-project file reaches the prompt
    expect(system).toHaveLength(2);
    expect(system[1]).toContain("INSIDE_SENTINEL_9d3f");
    // oracle: this string lives in a file outside the project root, written
    // independently of any source in this patch; a regressed escape check
    // leaks content the project does not own into every request's prompt.
    expect(system[1]).not.toContain("OUTSIDE_SENTINEL_c40b");
  });

  test("a file over the size cap is skipped and the under-cap control is injected", async () => {
    // #given an over-cap AGENTS.local.md next to an under-cap CLAUDE.local.md
    const root = temporaryDir("agents-local-cap-");
    await writeFile(join(root, "AGENTS.local.md"), "A".repeat(shared.MAX_LOCAL_INSTRUCTIONS_BYTES + 1));
    await writeFile(join(root, "CLAUDE.local.md"), "Under the cap UNDERCAP_SENTINEL_71ee.\n");
    const transform = await loadTransform(root);

    // #when the transform runs
    const system = [BASE_SYSTEM];
    await transform({}, { system });

    // #then the oversized file is not what was injected
    expect(system).toHaveLength(2);
    expect(system[1]).toContain("UNDERCAP_SENTINEL_71ee");
    // oracle: the run of "A" is the over-cap fixture's own bytes, sized from
    // the cap the shared module publishes; a regressed cap check pushes a
    // 50 KiB+ file into every request's system prompt.
    expect(system[1]).not.toContain("AAAAAAAAAA");
  });

  test("a directory named AGENTS.local.md leaves the prompt alone", async () => {
    // #given a directory where the instructions file would be
    const root = temporaryDir("agents-local-dir-");
    await mkdir(join(root, "AGENTS.local.md"));
    const transform = await loadTransform(root);

    // #when the transform runs
    const system = [BASE_SYSTEM];
    await transform({}, { system });

    // #then nothing was appended
    expect(system).toEqual([BASE_SYSTEM]);
  });
});

// --- scenario 3: idempotence (KTD11) ----------------------------------------

describe("heading-guarded idempotence (KTD11)", () => {
  test("a second call over an already-injected array appends nothing", async () => {
    // #given a system array the transform has already injected into
    const root = await projectWithAgentsLocal("Injected once IDEMPOTENT_SENTINEL_2b7c.\n");
    const transform = await loadTransform(root);
    const system = [BASE_SYSTEM];
    await transform({}, { system });
    const afterFirst = [...system];

    // #when the same array is transformed again
    await transform({}, { system });

    // #then the array is unchanged: one heading, one copy of the content
    expect(system).toEqual(afterFirst);
    expect(system.join("\n").split("IDEMPOTENT_SENTINEL_2b7c")).toHaveLength(2);
  });

  test("an array that already carries the heading is left alone", async () => {
    // #given an array carrying the heading from some earlier producer
    const root = await projectWithAgentsLocal("Would be injected NEW_SENTINEL_8f10.\n");
    const transform = await loadTransform(root);
    const preInjected = `${shared.LOCAL_INSTRUCTIONS_HEADING}\n\nsomething earlier`;
    const system = [BASE_SYSTEM, preInjected];

    // #when the transform runs
    await transform({}, { system });

    // #then it appends nothing
    expect(system).toEqual([BASE_SYSTEM, preInjected]);
  });
});

// --- scenario 4: nothing to inject ------------------------------------------

describe("no local instructions present", () => {
  test("the system array is untouched", async () => {
    // #given a project with neither local instructions file
    const root = temporaryDir("agents-local-empty-");
    await writeFile(join(root, "AGENTS.md"), "Repository instructions, not local ones.\n");
    const transform = await loadTransform(root);

    // #when the transform runs
    const system = [BASE_SYSTEM, "second entry"];
    await transform({}, { system });

    // #then nothing changed
    expect(system).toEqual([BASE_SYSTEM, "second entry"]);
  });
});

// --- scenario 5: the KTD11 boundary -----------------------------------------
//
// local-instructions shares the lib root with the dispatch core for deployment
// reasons only. An import edge in either direction would drag the core's
// pure-and-synchronous policy invariant onto a module that reads the
// filesystem, or drag filesystem I/O into the tool-call path.

const LOCAL_INSTRUCTIONS_FILE = "local-instructions.ts";

function importSpecifiers(source: string): string[] {
  const specifiers: string[] = [];
  const pattern = /(?:\bfrom\s*|\bimport\s*\(\s*)["']([^"']+)["']/g;
  for (const match of source.matchAll(pattern)) specifiers.push(match[1]);
  return specifiers;
}

function typescriptFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true, recursive: true } as any)
    .filter((entry: any) => entry.isFile() && entry.name.endsWith(".ts"))
    .map((entry: any) => join(entry.parentPath ?? entry.path ?? dir, entry.name));
}

/** Core files that name the shared module — the core-depends-on-it direction. */
function coreFilesReachingLocalInstructions(dir: string): string[] {
  return typescriptFiles(dir)
    .filter((path) => !path.endsWith(LOCAL_INSTRUCTIONS_FILE))
    .filter((path) => importSpecifiers(readFileSync(path, "utf8")).some((s) => s.includes("local-instructions")));
}

/** Non-builtin imports of the shared module — the it-depends-on-core direction. */
function localInstructionsNonBuiltinImports(dir: string): string[] {
  return importSpecifiers(readFileSync(join(dir, LOCAL_INSTRUCTIONS_FILE), "utf8")).filter(
    (specifier) => !specifier.startsWith("node:"),
  );
}

describe("no import edge to the dispatch core (KTD11)", () => {
  test("the scan detects an edge in either direction", () => {
    // #given a fake lib root where both edges exist
    const dir = temporaryDir("agents-local-edge-");
    writeFileSync(join(dir, LOCAL_INSTRUCTIONS_FILE), 'import { dispatch } from "./index.ts";\n');
    writeFileSync(join(dir, "registry.ts"), 'import { x } from "./local-instructions.ts";\n');
    writeFileSync(join(dir, "clean.ts"), 'import { join } from "node:path";\n');

    // #when both directions are scanned
    // #then each reports exactly its offender
    expect(coreFilesReachingLocalInstructions(dir).map((path) => path.endsWith("registry.ts"))).toEqual([true]);
    expect(localInstructionsNonBuiltinImports(dir)).toEqual(["./index.ts"]);
  });

  test("the shipped core and shared module import nothing from each other", () => {
    // #given the deployed lib root
    expect(typescriptFiles(CORE_DIR).length).toBeGreaterThan(1);

    // #when both directions are scanned
    // #then neither direction has an edge
    expect(coreFilesReachingLocalInstructions(CORE_DIR)).toEqual([]);
    expect(localInstructionsNonBuiltinImports(CORE_DIR)).toEqual([]);
  });
});
