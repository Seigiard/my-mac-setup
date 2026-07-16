import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { parseWorkEnvelope, runValidateCmd, secretScanDiff } from "./envelopes.ts";

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
});
