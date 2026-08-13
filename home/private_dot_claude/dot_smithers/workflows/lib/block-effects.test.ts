import { afterAll, describe, expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { runComputeEffect, type ComputeEffectContext, type GhRunner } from "./block-effects.ts";
import { buildRegistry } from "./blocks/index.ts";

const tempDirs: string[] = [];

function tempDir(prefix: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

function rawGit(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
}

function makeRepo(): string {
  const dir = tempDir("block-effects-repo-");
  rawGit(dir, "init", "-q", "-b", "main");
  rawGit(dir, "config", "user.email", "test@test.local");
  rawGit(dir, "config", "user.name", "Test");
  fs.writeFileSync(path.join(dir, "file.txt"), "hello\n");
  rawGit(dir, "add", ".");
  rawGit(dir, "commit", "-qm", "init");
  return dir;
}

function ctxFor(worktreePath: string, over: Partial<ComputeEffectContext> = {}): ComputeEffectContext {
  return {
    worktreePath,
    baseSha: rawGit(worktreePath, "rev-parse", "HEAD"),
    branch: "se/flow-run-abcdef01",
    runId: "run-abcdef01",
    ...over,
  };
}

// A fake gitleaks: exit 0 = clean, 2 = leaks found, matching the pinned
// --exit-code contract secretScanDiff relies on. Lets the effect's spawn path
// run deterministically without depending on real gitleaks detection rules.
function fakeGitleaks(exitCode: number): string {
  const dir = tempDir("fake-gitleaks-");
  const bin = path.join(dir, "gitleaks");
  fs.writeFileSync(bin, `#!/usr/bin/env bash\necho "fake gitleaks report"\nexit ${exitCode}\n`);
  fs.chmodSync(bin, 0o755);
  return bin;
}

const gitleaksAvailable = spawnSync("gitleaks", ["version"], { encoding: "utf8" }).status === 0;

const gate = (name: string) => buildRegistry().get(name)!.gateFn;

afterAll(() => {
  for (const dir of tempDirs) fs.rmSync(dir, { recursive: true, force: true });
});

describe("secret-scan effect", () => {
  test("clean scan → clean state, green gate", () => {
    const repo = makeRepo();
    const ctx = ctxFor(repo, { gitleaksBin: fakeGitleaks(0) });
    const out = runComputeEffect("secret-scan", {}, ctx) as { state: string };
    expect(out.state).toBe("clean");
    expect(gate("secret-scan")(out).state).toBe("green");
  });

  test("scanner reports a leak → found state, red gate", () => {
    const repo = makeRepo();
    const ctx = ctxFor(repo, { gitleaksBin: fakeGitleaks(2) });
    const out = runComputeEffect("secret-scan", {}, ctx) as { state: string };
    expect(out.state).toBe("found");
    expect(gate("secret-scan")(out).state).toBe("failed");
  });

  test.skipIf(!gitleaksAvailable)("real gitleaks catches a planted private key in the run commits → red gate", () => {
    const repo = makeRepo();
    const base = rawGit(repo, "rev-parse", "HEAD");
    fs.writeFileSync(
      path.join(repo, "leak.pem"),
      "-----BEGIN PRIVATE KEY-----\nMIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4wggE6AgEAAkEA\n-----END PRIVATE KEY-----\n",
    );
    rawGit(repo, "add", ".");
    rawGit(repo, "commit", "-qm", "oops secret");
    const out = runComputeEffect("secret-scan", { baseShaRef: base }, ctxFor(repo, { baseSha: base })) as { state: string };
    expect(out.state).toBe("found");
    expect(gate("secret-scan")(out).state).toBe("failed");
  });
});

describe("commit-work effect", () => {
  test("staged changes commit; head tree diverges from base → green gate", () => {
    const repo = makeRepo();
    const ctx = ctxFor(repo);
    fs.writeFileSync(path.join(repo, "new.txt"), "content\n");
    const out = runComputeEffect("commit-work", {}, ctx) as { baseTree: string; headTree: string; committed: boolean };
    expect(out.committed).toBe(true);
    expect(out.headTree).not.toBe(out.baseTree);
    expect(gate("commit-work")(out).state).toBe("green");
  });

  test("clean tree is a no-op; head tree equals base → red gate (no real change)", () => {
    const repo = makeRepo();
    const out = runComputeEffect("commit-work", {}, ctxFor(repo)) as { baseTree: string; headTree: string; committed: boolean };
    expect(out.committed).toBe(false);
    expect(out.headTree).toBe(out.baseTree);
    expect(gate("commit-work")(out).state).toBe("failed");
  });
});

describe("run-validate effect", () => {
  test("passing command records exitCode 0 → green gate", () => {
    const out = runComputeEffect("run-validate", { validateCmd: "exit 0" }, ctxFor(makeRepo())) as { exitCode: number | null };
    expect(out.exitCode).toBe(0);
    expect(gate("run-validate")(out).state).toBe("green");
  });

  test("failing command records its exit code → red gate", () => {
    const out = runComputeEffect("run-validate", { validateCmd: "exit 3" }, ctxFor(makeRepo())) as { exitCode: number | null };
    expect(out.exitCode).toBe(3);
    expect(gate("run-validate")(out).state).toBe("failed");
  });

  test("unresolved {ref} command is not executed → null exit, red gate (fail-closed)", () => {
    const out = runComputeEffect("run-validate", { validateCmd: { ref: "op://cmd" } }, ctxFor(makeRepo())) as { exitCode: number | null };
    expect(out.exitCode).toBeNull();
    expect(gate("run-validate")(out).state).toBe("failed");
  });
});

describe("proof-artifacts effect", () => {
  test("existing named files enter the manifest; missing names are dropped → green gate", () => {
    const repo = makeRepo();
    fs.writeFileSync(path.join(repo, "report.md"), "proof\n");
    const out = runComputeEffect("proof-artifacts", { names: ["report.md", "absent.txt"] }, ctxFor(repo)) as {
      manifest: { name: string; path: string }[];
    };
    expect(out.manifest.map((m) => m.name)).toEqual(["report.md"]);
    expect(out.manifest[0]!.path).toBe(path.resolve(repo, "report.md"));
    expect(gate("proof-artifacts")(out).state).toBe("green");
  });
});

describe("pr effect", () => {
  function stubGh(routes: Record<string, { status: number | null; stdout?: string; stderr?: string }>): GhRunner {
    return (args) => {
      const key = `${args[0]} ${args[1]}`;
      const r = routes[key] ?? { status: 1, stdout: "", stderr: `unrouted: ${key}` };
      return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
    };
  }

  test("unauthenticated gh → unauthenticated result, red gate", () => {
    const ctx = ctxFor(makeRepo(), { gh: stubGh({ "auth status": { status: 1 } }), push: () => ({ ok: true, stderr: "" }) });
    const out = runComputeEffect("pr", { title: "t" }, ctx) as { result: string };
    expect(out.result).toBe("unauthenticated");
    expect(gate("pr")(out).state).toBe("failed");
  });

  test("rejected push → push-rejected result, red gate", () => {
    const ctx = ctxFor(makeRepo(), {
      gh: stubGh({ "auth status": { status: 0 } }),
      push: () => ({ ok: false, stderr: "rejected" }),
    });
    const out = runComputeEffect("pr", { title: "t" }, ctx) as { result: string };
    expect(out.result).toBe("push-rejected");
    expect(gate("pr")(out).state).toBe("failed");
  });

  test("clean push with no existing PR → opened result with url, green gate", () => {
    const ctx = ctxFor(makeRepo(), {
      gh: stubGh({
        "auth status": { status: 0 },
        "pr view": { status: 1, stdout: "" },
        "pr create": { status: 0, stdout: "https://github.com/x/y/pull/1" },
      }),
      push: () => ({ ok: true, stderr: "" }),
    });
    const out = runComputeEffect("pr", { title: "t" }, ctx) as { result: string; url: string | null };
    expect(out.result).toBe("opened");
    expect(out.url).toBe("https://github.com/x/y/pull/1");
    expect(gate("pr")(out).state).toBe("green");
  });

  test("existing PR for the branch → exists result, green gate, no duplicate create", () => {
    const ctx = ctxFor(makeRepo(), {
      gh: stubGh({
        "auth status": { status: 0 },
        "pr view": { status: 0, stdout: "https://github.com/x/y/pull/7" },
      }),
      push: () => ({ ok: true, stderr: "" }),
    });
    const out = runComputeEffect("pr", { title: "t" }, ctx) as { result: string; url: string | null };
    expect(out.result).toBe("exists");
    expect(out.url).toBe("https://github.com/x/y/pull/7");
    expect(gate("pr")(out).state).toBe("green");
  });
});

describe("runComputeEffect dispatch", () => {
  test("an unregistered effect name throws rather than returning an empty payload", () => {
    expect(() => runComputeEffect("no-such-block", {}, ctxFor(makeRepo()))).toThrow(/no compute effect/);
  });
});
