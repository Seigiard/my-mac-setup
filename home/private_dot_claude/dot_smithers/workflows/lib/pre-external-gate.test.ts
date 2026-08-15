import { describe, expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  enforcePreExternalGate,
  preExternalDocGate,
  preExternalRepoGate,
  preExternalTreeGate,
  SCAN_OVERRIDE_ENV,
} from "./pre-external-gate.ts";
import { readReportFindings, resolveBaseline } from "./secret-baseline.ts";

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

// --- tier 2: the whole snapshot tree -------------------------------------

function stateDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "tree-gate-state-"));
}

// The gate exports the tree into a fresh `se-tree-scan-*` under the system temp
// dir. Listing them before and after is how a test can see the export was
// removed — the directory is the leak, so its absence is the assertion.
function exportDirs(): Set<string> {
  return new Set(fs.readdirSync(os.tmpdir()).filter((n) => n.startsWith("se-tree-scan-")));
}

function leftBehind(before: Set<string>): string[] {
  return [...exportDirs()].filter((n) => !before.has(n));
}

function commitSecret(repo: string, file: string): string {
  fs.writeFileSync(path.join(repo, file), `aws_access_key_id = "${FAKE_AWS_KEY}"\n`);
  git(repo, "add", "-A");
  git(repo, "commit", "-qm", `add ${file}`);
  return git(repo, "rev-parse", "HEAD");
}

describe("preExternalTreeGate", () => {
  test.skipIf(!gitleaksAvailable)("baseline нет → снимается с текущего скана, run проходит, заметка громкая", () => {
    // #given a repo whose BASE branch already carried a credential-shaped file
    // long before this run — invisible to any range scan
    const repo = makeRepo();
    const head = commitSecret(repo, "fixture.txt");
    const state = stateDir();

    // #when the tree gate runs for the first time on this repo
    const verdict = preExternalTreeGate({ repo, head, label: "se-code-review", stateDir: state, override: false });

    // #then it passes and says exactly what was baselined and where
    expect(verdict.state).toBe("pass");
    expect(verdict.reason).toContain("CAPTURED A NEW BASELINE");
    expect(verdict.reason).toContain(resolveBaseline(repo, { stateDir: state }).path);
    expect(verdict.reason).toContain("1 finding(s)");
    expect(verdict.reason).toContain("INVISIBLE to future runs");
  });

  test.skipIf(!gitleaksAvailable)("снятый baseline реально содержит находки, а не пустой файл", () => {
    // #given a first run that captured a baseline
    const repo = makeRepo();
    const head = commitSecret(repo, "fixture.txt");
    const state = stateDir();
    preExternalTreeGate({ repo, head, label: "se-code-review", stateDir: state, override: false });

    // #when the captured file is read back
    const findings = readReportFindings(resolveBaseline(repo, { stateDir: state }).path);

    // #then it carries the fingerprint the next run will match against
    expect(findings.map((f) => f.fingerprint)).toEqual(["fixture.txt:aws-access-token:1"]);
  });

  test.skipIf(!gitleaksAvailable)("baseline есть, дерево не менялось → pass", () => {
    // #given a repo already baselined
    const repo = makeRepo();
    const head = commitSecret(repo, "fixture.txt");
    const state = stateDir();
    preExternalTreeGate({ repo, head, label: "se-code-review", stateDir: state, override: false });

    // #when the same tree is gated again (a fresh export directory each time)
    const verdict = preExternalTreeGate({ repo, head, label: "se-code-review", stateDir: state, override: false });

    // #then the repo's own fixtures do not block the run
    expect(verdict.state).toBe("pass");
    expect(verdict.reason).toContain("clean");
  });

  test.skipIf(!gitleaksAvailable)("находка вне baseline → refuse, и она названа", () => {
    // #given a baselined repo that then gains a NEW secret elsewhere in the tree
    const repo = makeRepo();
    const state = stateDir();
    preExternalTreeGate({ repo, head: commitSecret(repo, "fixture.txt"), label: "se-simplify", stateDir: state, override: false });
    const head = commitSecret(repo, "leaked.txt");

    // #when the tree is gated again
    const verdict = preExternalTreeGate({ repo, head, label: "se-simplify", stateDir: state, override: false });

    // #then only the new finding stops the run, and the message names it
    expect(verdict.state).toBe("refuse");
    expect(verdict.reason).toContain("leaked.txt:aws-access-token:1");
    expect(verdict.reason).not.toContain("fixture.txt");
    expect(verdict.reason).not.toContain(FAKE_AWS_KEY);
  });

  test("сканер не запустился → refuse (fail-closed), а не pass", () => {
    // #given no gitleaks binary at the configured path
    const repo = makeRepo();

    // #when the tree gate runs
    const verdict = preExternalTreeGate({
      repo,
      head: git(repo, "rev-parse", "HEAD"),
      label: "se-code-review",
      bin: "/no/such/gitleaks-bin",
      stateDir: stateDir(),
      override: false,
    });

    // #then an unscanned tree is never sent, and no baseline is invented
    expect(verdict.state).toBe("refuse");
    expect(verdict.reason).toContain("could NOT run");
  });

  test("пустой head → refuse: экспортировать нечего", () => {
    // #given a caller that could not resolve the snapshot commit
    const repo = makeRepo();

    // #when the tree gate runs
    const verdict = preExternalTreeGate({ repo, head: "", label: "se-code-review", stateDir: stateDir(), override: false });

    // #then it refuses rather than scanning an undefined tree
    expect(verdict.state).toBe("refuse");
    expect(verdict.reason).toContain("no commit to export");
  });

  test("override → скан не запускается и baseline не пишется", () => {
    // #given a repo with a secret and a scanner that would report it
    const repo = makeRepo();
    const head = commitSecret(repo, "fixture.txt");
    const state = stateDir();

    // #when the operator overrides the gate
    const verdict = preExternalTreeGate({ repo, head, label: "se-code-review", bin: fakeGitleaks(2), stateDir: state, override: true });

    // #then the run continues unscanned, and no baseline was silently created
    expect(verdict.state).toBe("pass");
    expect(verdict.reason).toContain("SKIPPED");
    expect(resolveBaseline(repo, { stateDir: state }).exists).toBe(false);
  });

  test(`${SCAN_OVERRIDE_ENV} из окружения пропускает tier 2, как и tier 1`, () => {
    // #given the operator's per-invocation escape hatch in the environment
    const repo = makeRepo();
    const head = git(repo, "rev-parse", "HEAD");
    const previous = process.env[SCAN_OVERRIDE_ENV];
    process.env[SCAN_OVERRIDE_ENV] = "1";

    // #when the gate runs with no explicit override argument
    try {
      const verdict = preExternalTreeGate({ repo, head, label: "se-code-review", bin: "/no/such/gitleaks-bin", stateDir: stateDir() });

      // #then the env var alone skips the tier, exactly as it does for the range
      expect(verdict.state).toBe("pass");
      expect(verdict.reason).toContain("SKIPPED");
    } finally {
      if (previous === undefined) delete process.env[SCAN_OVERRIDE_ENV];
      else process.env[SCAN_OVERRIDE_ENV] = previous;
    }
  });

  test.skipIf(!gitleaksAvailable)("экспорт дерева удаляется и на pass, и на refuse", () => {
    // #given a baselined repo that then gains a new secret
    const repo = makeRepo();
    const state = stateDir();
    const before = exportDirs();
    preExternalTreeGate({ repo, head: commitSecret(repo, "fixture.txt"), label: "se-code-review", stateDir: state, override: false });
    const pass = preExternalTreeGate({ repo, head: git(repo, "rev-parse", "HEAD"), label: "se-code-review", stateDir: state, override: false });
    const refuse = preExternalTreeGate({ repo, head: commitSecret(repo, "leaked.txt"), label: "se-code-review", stateDir: state, override: false });

    // #when both verdicts have been produced
    expect(pass.state).toBe("pass");
    expect(refuse.state).toBe("refuse");

    // #then no readable copy of the tree — least of all the refused one — is
    // left lying in /tmp
    expect(leftBehind(before)).toEqual([]);
  });

  test.skipIf(!gitleaksAvailable)("одно и то же дерево под двумя разными корнями → один baseline закрывает оба", () => {
    // #given two checkouts with byte-identical content, each exported to its own
    // fresh temp root — the shape every run has, since mkdtemp never repeats.
    // A `dir` scan's fingerprints are relative to the target ARGUMENT, so this
    // only holds because the scan runs with cwd=root and target ".".
    const a = makeRepo();
    const b = makeRepo();
    const headA = commitSecret(a, "fixture.txt");
    const headB = commitSecret(b, "fixture.txt");
    const state = stateDir();
    const captured = preExternalTreeGate({ repo: a, head: headA, label: "se-code-review", stateDir: state, override: false });
    expect(captured.state).toBe("pass");

    // #when A's baseline is handed to B
    fs.copyFileSync(resolveBaseline(a, { stateDir: state }).path, resolveBaseline(b, { stateDir: state }).path);
    const verdict = preExternalTreeGate({ repo: b, head: headB, label: "se-code-review", stateDir: state, override: false });

    // #then B passes: fingerprints are root-independent. If this test fails,
    // every second run re-refuses the findings its own first run baselined.
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
