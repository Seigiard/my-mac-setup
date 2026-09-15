import { afterEach, describe, expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const OPENCODE_LOADER = join(
  import.meta.dir,
  "../home/private_dot_config/opencode/plugins/agent-intercom.ts",
);
const PI_LOADER = join(import.meta.dir, "../home/dot_pi/agent/extensions/agent-intercom.ts");
const PACKAGE_MANIFEST = join(
  import.meta.dir,
  "../home/dot_local/share/agent-intercom/package.json",
);
const PACKAGE_LOCK = join(
  import.meta.dir,
  "../home/dot_local/share/agent-intercom/package-lock.json",
);
const temporaryPaths: string[] = [];
let loadCount = 0;

function temporaryDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  temporaryPaths.push(dir);
  return dir;
}

function packageRoot(home: string): string {
  return join(home, ".local", "share", "agent-intercom", "node_modules");
}

async function loadFromHome(loader: string, home: string, herdr: boolean): Promise<any> {
  const copy = join(temporaryDir("agent-intercom-loader-"), `loader-${loadCount++}.ts`);
  cpSync(loader, copy);
  const previousHome = process.env.HOME;
  const previousHerdr = process.env.HERDR_ENV;
  process.env.HOME = home;
  if (herdr) process.env.HERDR_ENV = "1";
  else delete process.env.HERDR_ENV;
  try {
    return await import(copy);
  } finally {
    process.env.HOME = previousHome;
    if (previousHerdr === undefined) delete process.env.HERDR_ENV;
    else process.env.HERDR_ENV = previousHerdr;
  }
}

afterEach(() => {
  for (const path of temporaryPaths.splice(0)) rmSync(path, { recursive: true, force: true });
});

describe("Agent Intercom package pins", () => {
  test("the managed package set names every tested revision exactly", () => {
    const manifest = JSON.parse(readFileSync(PACKAGE_MANIFEST, "utf8"));
    expect(manifest.dependencies).toEqual({
      "@dataforxyz/agent-intercom-core":
        "git+https://github.com/dataforxyz/agent-intercom-core.git#8316cbab548f422ad11c78ed887fabeef94817c1",
      "@dataforxyz/agent-intercom-claude":
        "git+https://github.com/dataforxyz/agent-intercom-claude.git#7de76e5d4f6461b007b19dfc5dbcf11928868adc",
      "@dataforxyz/agent-intercom-opencode":
        "git+https://github.com/dataforxyz/agent-intercom-opencode.git#91ce62f03f14b89ea11fc39eedf7d44bca808cf4",
      "@dataforxyz/agent-intercom-pi":
        "git+https://github.com/dataforxyz/agent-intercom-pi.git#0fffed27d15055b866fe4e52803be6adcd363051",
    });
  });

  test("the lock resolves every git dependency over portable HTTPS URLs", () => {
    const lock = JSON.parse(readFileSync(PACKAGE_LOCK, "utf8"));
    const packages = lock.packages as Record<string, { resolved?: string }>;
    for (const name of [
      "agent-intercom-core",
      "agent-intercom-claude",
      "agent-intercom-opencode",
      "agent-intercom-pi",
    ]) {
      const entry = packages[`node_modules/@dataforxyz/${name}`];
      expect(entry.resolved).toStartWith(`git+https://github.com/dataforxyz/${name}.git#`);
    }
  });

  test("every registry artifact has a recorded integrity hash", () => {
    const lock = JSON.parse(readFileSync(PACKAGE_LOCK, "utf8"));
    const packages = Object.entries(lock.packages) as Array<
      [string, { resolved?: string; integrity?: string }]
    >;
    const missing = packages
      .filter(([, entry]) => entry.resolved?.startsWith("https://registry.npmjs.org/"))
      .filter(([, entry]) => !entry.integrity)
      .map(([path]) => path);
    expect(missing).toEqual([]);
  });
});

describe("OpenCode Agent Intercom loader", () => {
  test("loads the server plugin entrypoint without touching root or TUI modules", async () => {
    const home = temporaryDir("agent-intercom-opencode-home-");
    const packageDir = join(packageRoot(home), "@dataforxyz", "agent-intercom-opencode");
    mkdirSync(join(packageDir, "dist"), { recursive: true });
    await Bun.write(
      join(packageDir, "dist", "plugin.mjs"),
      "export default async () => ({ transport: 'server' });\n",
    );
    await Bun.write(join(packageDir, "dist", "index.mjs"), "throw new Error('root loaded');\n");
    await Bun.write(join(packageDir, "dist", "tui.mjs"), "throw new Error('tui loaded');\n");

    const module = await loadFromHome(OPENCODE_LOADER, home, true);
    expect(Object.keys(module)).toEqual(["AgentIntercomPlugin"]);
    expect(await module.AgentIntercomPlugin({})).toEqual({ transport: "server" });
  });

  test("is a no-op outside Herdr without importing the package", async () => {
    const home = temporaryDir("agent-intercom-opencode-missing-");
    const module = await loadFromHome(OPENCODE_LOADER, home, false);
    expect(await module.AgentIntercomPlugin({})).toEqual({});
  });

  test("fails at load time inside Herdr when the managed package is absent", async () => {
    const home = temporaryDir("agent-intercom-opencode-missing-herdr-");
    await expect(loadFromHome(OPENCODE_LOADER, home, true)).rejects.toThrow();
  });
});

describe("Pi Agent Intercom loader", () => {
  test("loads and delegates to the native Pi extension", async () => {
    const home = temporaryDir("agent-intercom-pi-home-");
    const packageDir = join(packageRoot(home), "@dataforxyz", "agent-intercom-pi");
    mkdirSync(packageDir, { recursive: true });
    await Bun.write(
      join(packageDir, "index.ts"),
      "export default (pi: any) => { pi.transport = 'native'; };\n",
    );

    const module = await loadFromHome(PI_LOADER, home, true);
    const pi: Record<string, unknown> = {};
    module.default(pi);
    expect(pi).toEqual({ transport: "native" });
  });

  test("is a no-op outside Herdr without importing the package", async () => {
    const home = temporaryDir("agent-intercom-pi-missing-");
    const module = await loadFromHome(PI_LOADER, home, false);
    const pi: Record<string, unknown> = {};
    module.default(pi);
    expect(pi).toEqual({});
  });

  test("fails at load time inside Herdr when the managed package is absent", async () => {
    const home = temporaryDir("agent-intercom-pi-missing-herdr-");
    await expect(loadFromHome(PI_LOADER, home, true)).rejects.toThrow();
  });
});
