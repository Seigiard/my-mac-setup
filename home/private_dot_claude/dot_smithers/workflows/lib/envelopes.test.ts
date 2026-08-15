import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { exportTreeAt, parseWorkEnvelope, runValidateCmd, secretScanDiff, secretScanPath, secretScanTree } from "./envelopes.ts";

function envelopeJson(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({
    status: "complete",
    plan_path: "/abs/plan.md",
    changed_files: ["src/a.ts"],
    u_ids_attempted: ["U1"],
    u_ids_completed: ["U1"],
    verification_results: { "bun test": "green" },
    verification_evidence: [{ unit: "U1", behavior_changed: true }],
    blockers: [],
    behavior_change: true,
    standalone_shipping_skipped: true,
    final_commit_sha: "a".repeat(40),
    ...overrides,
  });
}

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
}

function makeRepo(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "envelopes-test-"));
  execFileSync("git", ["init", "-q", "-b", "main", dir]);
  git(dir, "config", "user.email", "t@t");
  git(dir, "config", "user.name", "t");
  fs.writeFileSync(path.join(dir, "README.md"), "base\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-qm", "base");
  return dir;
}

describe("parseWorkEnvelope", () => {
  test("happy: полный конверт → ok с полями", () => {
    const r = parseWorkEnvelope(envelopeJson());
    if (!r.ok) throw new Error(r.reason);
    expect(r.envelope.status).toBe("complete");
    expect(r.envelope.final_commit_sha).toBe("a".repeat(40));
    expect(r.envelope.verification_evidence.length).toBe(1);
  });

  test("обрезанный JSON → ok:false с причиной парса", () => {
    const r = parseWorkEnvelope('{"status":"comp');
    expect(r.ok).toBe(false);
    if (r.ok) throw new Error("expected failure");
    expect(r.reason.toLowerCase()).toContain("parse");
  });

  test("нет конверта → ok:false", () => {
    const r = parseWorkEnvelope(undefined);
    expect(r.ok).toBe(false);
  });

  test("нет status → ok:false (схема)", () => {
    const raw = JSON.stringify({ changed_files: [] });
    const r = parseWorkEnvelope(raw);
    expect(r.ok).toBe(false);
  });

  test("final_commit_sha опционален (документированный конверт без SHA парсится)", () => {
    const r = parseWorkEnvelope(envelopeJson({ final_commit_sha: undefined }));
    if (!r.ok) throw new Error(r.reason);
    expect(r.envelope.final_commit_sha).toBeUndefined();
  });
});

describe("runValidateCmd", () => {
  test("успешная команда → exitCode 0 и вывод", () => {
    const r = runValidateCmd("echo validate-ok", os.tmpdir());
    expect(r.exitCode).toBe(0);
    expect(r.output).toContain("validate-ok");
  });

  test("падение → ненулевой exitCode, без throw", () => {
    const r = runValidateCmd("exit 3", os.tmpdir());
    expect(r.exitCode).toBe(3);
  });

  test("несуществующая команда → ненулевой exitCode", () => {
    const r = runValidateCmd("definitely-no-such-cmd-xyz", os.tmpdir());
    expect(r.exitCode).not.toBe(0);
  });

  test("таймаут убивает всю process-group, не только оболочку", () => {
    // #given команда, породившая внука (sleep), который переживал bash
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "se-validate-pg-"));
    const pidFile = path.join(dir, "orphan.pid");

    // #when validate-cmd убит по таймауту
    const r = runValidateCmd(`sleep 30 & echo $! > orphan.pid; wait`, dir, 800);

    // #then сам вызов провален, а внук НЕ пережил kill группы
    expect(r.exitCode).not.toBe(0);
    const orphanPid = Number(fs.readFileSync(pidFile, "utf8").trim());
    expect(Number.isInteger(orphanPid) && orphanPid > 1).toBe(true);
    const deadline = Date.now() + 2_000;
    let alive = true;
    while (alive && Date.now() < deadline) {
      try {
        process.kill(orphanPid, 0);
        Bun.sleepSync(100);
      } catch {
        alive = false;
      }
    }
    expect(alive).toBe(false);
  });
});

describe("secretScanDiff (gitleaks, KTD10)", () => {
  test("чистый дифф → clean", () => {
    const repo = makeRepo();
    const base = git(repo, "rev-parse", "HEAD");
    fs.writeFileSync(path.join(repo, "code.ts"), "export const x = 1;\n");
    git(repo, "add", "-A");
    git(repo, "commit", "-qm", "clean change");
    const r = secretScanDiff(repo, base);
    expect(r.state).toBe("clean");
  });

  test("подсаженный AWS-ключ в диффе → found", () => {
    const repo = makeRepo();
    const base = git(repo, "rev-parse", "HEAD");
    const fakeKey = "AKIA" + "QWERTYUIOPASDFGH";
    fs.writeFileSync(path.join(repo, "config.ts"), `const awsAccessKeyId = "${fakeKey}";\n`);
    git(repo, "add", "-A");
    git(repo, "commit", "-qm", "oops");
    const r = secretScanDiff(repo, base);
    expect(r.state).toBe("found");
    expect(r.details.length).toBeGreaterThan(0);
    // --redact: the raw secret must never appear in the persisted details.
    expect(r.details).not.toContain(fakeKey);
  });

  test("сканер недоступен (нет бинарника) → error, не clean", () => {
    const repo = makeRepo();
    const base = git(repo, "rev-parse", "HEAD");
    const r = secretScanDiff(repo, base, { bin: "/no/such/gitleaks-bin" });
    expect(r.state).toBe("error");
  });

  test("снимок stash create: без includeMergeDiffs скан слеп, с ним — found", () => {
    // #given an uncommitted AWS key frozen into a `git stash create` snapshot —
    // the commit the standalone harnesses hand to the external legs
    const repo = makeRepo();
    const base = git(repo, "rev-parse", "HEAD");
    const fakeKey = "AKIA" + "QWERTYUIOPASDFGH";
    fs.writeFileSync(path.join(repo, "README.md"), `const awsAccessKeyId = "${fakeKey}";\n`);
    const snapshotSha = git(repo, "stash", "create");

    // #when the range is scanned without and with merge diffs
    const blind = secretScanDiff(repo, base, { head: snapshotSha });
    const seeing = secretScanDiff(repo, base, { head: snapshotSha, includeMergeDiffs: true });

    // #then the plain range reports clean (git log -p prints no patch for the
    // stash MERGE commit) and only the merge-diff scan sees the leak — which is
    // why the pre-external gate always passes includeMergeDiffs
    expect(blind.state).toBe("clean");
    expect(seeing.state).toBe("found");
  });
});

describe("exportTreeAt", () => {
  test("экспортирует только ОТСЛЕЖИВАЕМОЕ дерево коммита, без рабочего мусора", () => {
    // #given a repo whose worktree also holds build output — the state a
    // pipeline run worktree is in after setupCmd (`bun install && turbo build`)
    const repo = makeRepo();
    fs.writeFileSync(path.join(repo, "src.ts"), "export const x = 1;\n");
    git(repo, "add", "-A");
    git(repo, "commit", "-qm", "src");
    fs.mkdirSync(path.join(repo, "node_modules"));
    fs.writeFileSync(path.join(repo, "node_modules", "junk.js"), "junk\n");

    // #when the commit's tree is exported
    const exported = exportTreeAt(repo, git(repo, "rev-parse", "HEAD"));

    // #then the scan root carries repository content and nothing else
    try {
      expect(fs.readdirSync(exported.scanRoot).sort()).toEqual(["README.md", "src.ts"]);
    } finally {
      fs.rmSync(exported.tmpRoot, { recursive: true, force: true });
    }
  });

  test("несуществующий sha → throw и НИ ОДНОГО каталога-остатка", () => {
    // #given a repo and a commit that is not in it
    const repo = makeRepo();
    const before = fs.readdirSync(os.tmpdir()).filter((n) => n.startsWith("se-tree-scan-"));

    // #when the export fails
    expect(() => exportTreeAt(repo, "0".repeat(40))).toThrow();

    // #then the half-made export directory is not left in /tmp
    const after = fs.readdirSync(os.tmpdir()).filter((n) => n.startsWith("se-tree-scan-"));
    expect(after.filter((n) => !before.includes(n))).toEqual([]);
  });
});

describe("secretScanTree (gitleaks dir, cwd=root)", () => {
  test("fingerprint не зависит от абсолютного корня — иначе baseline не переживёт mkdtemp", () => {
    // #given the same content under two different roots
    const key = "AKIA" + "QWERTYUIOPASDFGH";
    const roots = ["a", "b"].map((name) => {
      const root = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "scan-tree-")), name);
      fs.mkdirSync(path.join(root, "sub"), { recursive: true });
      fs.writeFileSync(path.join(root, "sub", "creds.txt"), `aws_access_key_id = "${key}"\n`);
      return root;
    });

    // #when each is scanned with a report
    const fingerprints = roots.map((root) => {
      const report = path.join(path.dirname(root), "report.json");
      expect(secretScanTree(root, { reportPath: report }).state).toBe("found");
      return (JSON.parse(fs.readFileSync(report, "utf8")) as { Fingerprint: string }[]).map((f) => f.Fingerprint);
    });

    // #then both report the same path-relative fingerprint, which is what makes
    // one baseline reusable across every fresh export directory
    expect(fingerprints[0]).toEqual(["sub/creds.txt:aws-access-token:1"]);
    expect(fingerprints[1]).toEqual(fingerprints[0]);
  });

  test("baselinePath гасит известные находки, но не новую", () => {
    // #given a scanned tree whose report is promoted to a baseline
    const key = "AKIA" + "QWERTYUIOPASDFGH";
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "scan-tree-baseline-"));
    const dataDir = path.join(root, "tree");
    fs.mkdirSync(dataDir);
    fs.writeFileSync(path.join(dataDir, "fixture.txt"), `aws_access_key_id = "${key}"\n`);
    const baseline = path.join(root, "baseline.json");
    expect(secretScanTree(dataDir, { reportPath: baseline }).state).toBe("found");

    // #when the same tree, then the tree plus a new secret, are rescanned
    const unchanged = secretScanTree(dataDir, { reportPath: path.join(root, "r1.json"), baselinePath: baseline });
    fs.writeFileSync(path.join(dataDir, "leaked.txt"), `aws_access_key_id = "AKIA${"ZXCVBNMASDFGHJKL"}"\n`);
    const changed = secretScanTree(dataDir, { reportPath: path.join(root, "r2.json"), baselinePath: baseline });

    // #then the baseline suppresses exactly what it contains and nothing more
    expect(unchanged.state).toBe("clean");
    expect(changed.state).toBe("found");
  });

  test("сканер недоступен → error, не clean", () => {
    // #given a tree and no scanner binary
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "scan-tree-nobin-"));

    // #when it is scanned
    // #then the caller can fail closed
    expect(secretScanTree(root, { bin: "/no/such/gitleaks-bin" }).state).toBe("error");
  });
});

describe("secretScanPath (gitleaks dir)", () => {
  test("файл с ключом → found, без сырого секрета в деталях", () => {
    // #given a standalone document carrying a pasted credential
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "scan-path-"));
    const doc = path.join(dir, "plan.md");
    const fakeKey = "AKIA" + "QWERTYUIOPASDFGH";
    fs.writeFileSync(doc, `aws_access_key_id = "${fakeKey}"\n`);

    // #when it is scanned on disk (no git history involved)
    const r = secretScanPath(doc);

    // #then the leak is reported and --redact keeps the raw key out of details
    expect(r.state).toBe("found");
    expect(r.details).not.toContain(fakeKey);
  });

  test("чистый файл → clean", () => {
    // #given a document with no secret
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "scan-path-"));
    const doc = path.join(dir, "plan.md");
    fs.writeFileSync(doc, "# Plan\n\n- U1. Do the thing.\n");

    // #when it is scanned
    const r = secretScanPath(doc);

    // #then nothing blocks it
    expect(r.state).toBe("clean");
  });
});
