import { describe, expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  enforcePreExternalGate,
  preExternalDocGate,
  preExternalRepoGate,
  SCAN_OVERRIDE_ENV,
} from "./pre-external-gate.ts";

// A planted key that gitleaks detects, assembled at runtime so this test file is
// not itself a finding when the repo is scanned.
const FAKE_AWS_KEY = "AKIA" + "QWERTYUIOPASDFGH";

const gitleaksAvailable = spawnSync("gitleaks", ["version"], { encoding: "utf8" }).status === 0;

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
}

function makeRepo(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pre-external-gate-"));
  execFileSync("git", ["init", "-q", "-b", "main", dir]);
  git(dir, "config", "user.email", "t@t");
  git(dir, "config", "user.name", "t");
  fs.writeFileSync(path.join(dir, "README.md"), "base\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-qm", "base");
  return dir;
}

// A fake gitleaks with a pinned exit code: 0 clean, 2 leaks, anything else an
// error. Keeps the policy tests independent of real detection rules.
function fakeGitleaks(exitCode: number): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fake-gitleaks-"));
  const bin = path.join(dir, "gitleaks");
  fs.writeFileSync(bin, `#!/usr/bin/env bash\necho "fake gitleaks report"\nexit ${exitCode}\n`);
  fs.chmodSync(bin, 0o755);
  return bin;
}

describe("preExternalRepoGate", () => {
  test("чистый диапазон → pass", () => {
    // #given a repo whose only new commit carries no secret
    const repo = makeRepo();
    const base = git(repo, "rev-parse", "HEAD");
    fs.writeFileSync(path.join(repo, "code.ts"), "export const x = 1;\n");
    git(repo, "add", "-A");
    git(repo, "commit", "-qm", "clean change");

    // #when the gate scans base..HEAD
    const verdict = preExternalRepoGate({
      repo,
      baseSha: base,
      head: git(repo, "rev-parse", "HEAD"),
      label: "se-code-review",
      bin: fakeGitleaks(0),
      override: false,
    });

    // #then the snapshot may go to the external legs
    expect(verdict.state).toBe("pass");
  });

  test("сканер нашёл секрет → refuse с редактированными деталями и подсказкой override", () => {
    // #given a scanner reporting leaks in the range
    const repo = makeRepo();
    const base = git(repo, "rev-parse", "HEAD");

    // #when the gate runs
    const verdict = preExternalRepoGate({
      repo,
      baseSha: base,
      head: base,
      label: "se-code-review",
      bin: fakeGitleaks(2),
      override: false,
    });

    // #then the run is refused, and the message says how to proceed anyway
    expect(verdict.state).toBe("refuse");
    expect(verdict.reason).toContain("REFUSED");
    expect(verdict.reason).toContain(SCAN_OVERRIDE_ENV);
  });

  test("сканер не запустился → refuse (fail-closed), а не pass", () => {
    // #given no gitleaks binary at the configured path
    const repo = makeRepo();
    const base = git(repo, "rev-parse", "HEAD");

    // #when the gate runs
    const verdict = preExternalRepoGate({
      repo,
      baseSha: base,
      head: base,
      label: "se-simplify",
      bin: "/no/such/gitleaks-bin",
      override: false,
    });

    // #then an unscannable snapshot is never sent
    expect(verdict.state).toBe("refuse");
    expect(verdict.reason).toContain("could NOT run");
  });

  test("пустой base → refuse: диапазона для скана нет", () => {
    // #given a caller that could not resolve a base commit
    const repo = makeRepo();

    // #when the gate runs with an empty range start
    const verdict = preExternalRepoGate({
      repo,
      baseSha: "",
      head: git(repo, "rev-parse", "HEAD"),
      label: "se-code-review",
      bin: fakeGitleaks(0),
      override: false,
    });

    // #then it refuses instead of scanning an unbounded or malformed range
    expect(verdict.state).toBe("refuse");
    expect(verdict.reason).toContain("no commit range");
  });

  test("override → pass без вызова сканера, причина называет пропуск", () => {
    // #given a scanner that would report leaks
    const repo = makeRepo();
    const base = git(repo, "rev-parse", "HEAD");

    // #when the operator overrides the gate
    const verdict = preExternalRepoGate({
      repo,
      baseSha: base,
      head: base,
      label: "se-code-review",
      bin: fakeGitleaks(2),
      override: true,
    });

    // #then the run continues, and the reason records that nothing was scanned
    expect(verdict.state).toBe("pass");
    expect(verdict.reason).toContain("SKIPPED");
  });

  test.skipIf(!gitleaksAvailable)(
    "реальный gitleaks: секрет в ГРЯЗНОМ дереве через stash-снимок → refuse",
    () => {
      // #given an uncommitted key in a tracked file — the exact content a
      // `git stash create` snapshot ships to the external legs, and the case a
      // plain base..HEAD scan misses entirely (merge commits show no patch)
      const repo = makeRepo();
      const base = git(repo, "rev-parse", "HEAD");
      fs.writeFileSync(path.join(repo, "README.md"), `const awsAccessKeyId = "${FAKE_AWS_KEY}";\n`);
      const snapshotSha = git(repo, "stash", "create");

      // #when the gate scans the snapshot commit
      const verdict = preExternalRepoGate({ repo, baseSha: base, head: snapshotSha, label: "se-code-review", override: false });

      // #then the leak is caught before staging, and the raw key is not echoed
      expect(verdict.state).toBe("refuse");
      expect(verdict.reason).not.toContain(FAKE_AWS_KEY);
    },
  );

  test.skipIf(!gitleaksAvailable)("реальный gitleaks: чистое грязное дерево → pass", () => {
    // #given uncommitted changes with no secret
    const repo = makeRepo();
    const base = git(repo, "rev-parse", "HEAD");
    fs.writeFileSync(path.join(repo, "README.md"), "just an edit\n");
    const snapshotSha = git(repo, "stash", "create");

    // #when the gate scans the snapshot commit
    const verdict = preExternalRepoGate({ repo, baseSha: base, head: snapshotSha, label: "se-code-review", override: false });

    // #then an ordinary working tree is not blocked
    expect(verdict.state).toBe("pass");
  });
});

describe("preExternalDocGate", () => {
  test.skipIf(!gitleaksAvailable)("план без секретов → pass", () => {
    // #given an ordinary plan document
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pre-external-doc-"));
    const doc = path.join(dir, "plan.md");
    fs.writeFileSync(doc, "# Plan\n\n- U1. Do the thing.\n- Secrets stay in 1Password (op://Private/Token/credential).\n");

    // #when the gate scans it
    const verdict = preExternalDocGate({ docPath: doc, label: "se-doc-review", override: false });

    // #then the document goes to the external legs
    expect(verdict.state).toBe("pass");
  });

  test.skipIf(!gitleaksAvailable)("вставленный ключ в плане → refuse", () => {
    // #given a plan with a pasted credential
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pre-external-doc-"));
    const doc = path.join(dir, "plan.md");
    fs.writeFileSync(doc, `# Plan\n\nUse this key while testing: aws_access_key_id = "${FAKE_AWS_KEY}"\n`);

    // #when the gate scans it
    const verdict = preExternalDocGate({ docPath: doc, label: "se-doc-review", override: false });

    // #then it never reaches the external legs, and the key is not echoed
    expect(verdict.state).toBe("refuse");
    expect(verdict.reason).not.toContain(FAKE_AWS_KEY);
  });
});

describe("enforcePreExternalGate", () => {
  test("refuse → throw, чтобы stage упал до создания снимка", () => {
    // #given a refusal verdict
    const verdict = { state: "refuse" as const, reason: "se-code-review: pre-external secret gate REFUSED — planted" };

    // #when it is enforced
    // #then the stage task fails instead of staging anything
    expect(() => enforcePreExternalGate(verdict, () => {})).toThrow(/REFUSED/);
  });

  test("pass → лог с доказательством, что гейт отработал", () => {
    // #given a passing verdict
    const logged: string[] = [];

    // #when it is enforced
    enforcePreExternalGate({ state: "pass", reason: "se-simplify: pre-external secret scan clean" }, (m) => logged.push(m));

    // #then the run log carries the evidence
    expect(logged).toEqual(["se-simplify: pre-external secret scan clean"]);
  });
});
