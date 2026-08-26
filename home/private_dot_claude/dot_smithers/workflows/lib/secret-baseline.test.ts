import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { captureBaseline, readReportFindings, repoIdentity, resolveBaseline } from "./secret-baseline.ts";

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8" }).trim();
}

function makeRepo(): string {
  // macOS /tmp is a symlink to /private/tmp; realpath so the path git reports
  // and the path the test passes in are the same string.
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "secret-baseline-")));
  execFileSync("git", ["init", "-q", "-b", "main", dir]);
  git(dir, "config", "user.email", "t@t");
  git(dir, "config", "user.name", "t");
  fs.writeFileSync(path.join(dir, "README.md"), "base\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-qm", "base");
  return dir;
}

function stateDir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), "secret-baseline-state-"));
}

describe("repoIdentity", () => {
  test("основной чекаут → его собственный корень", () => {
    // #given an ordinary repository
    const repo = makeRepo();

    // #when its identity is resolved
    const identity = repoIdentity(repo);

    // #then it is the repo root itself
    expect(identity).toBe(repo);
  });

  test("связанный worktree → корень РЕПОЗИТОРИЯ, а не путь worktree", () => {
    // #given a linked worktree — what a pipeline run actually scans
    const repo = makeRepo();
    const wt = path.join(fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "secret-baseline-wt-"))), "run");
    git(repo, "worktree", "add", "--detach", "-q", wt, "HEAD");

    // #when the worktree's identity is resolved
    const identity = repoIdentity(wt);

    // #then it collapses to the one repository, so a per-run worktree cannot
    // mint a fresh baseline (which would auto-approve every finding each run)
    expect(identity).toBe(repo);
  });

  test("не-репозиторий → throw, чтобы гейт закрылся", () => {
    // #given a directory outside any git repository
    const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "secret-baseline-plain-")));

    // #when its identity is resolved
    // #then it throws rather than inventing a key the caller cannot trust
    expect(() => repoIdentity(dir)).toThrow();
  });
});

describe("resolveBaseline", () => {
  test("путь лежит в stateDir, а НЕ в целевом репозитории", () => {
    // #given a target repo that belongs to somebody else
    const repo = makeRepo();
    const state = stateDir();

    // #when the baseline is resolved
    const ref = resolveBaseline(repo, { stateDir: state });

    // #then nothing is ever written inside the target
    expect(ref.path.startsWith(path.join(state, "secret-baseline"))).toBe(true);
    expect(ref.path.startsWith(repo)).toBe(false);
  });

  test("имя файла = basename репозитория + дайджест абсолютного пути", () => {
    // #given a repo whose basename alone is not unique across checkouts
    const repo = makeRepo();

    // #when the baseline is resolved
    const ref = resolveBaseline(repo, { stateDir: stateDir() });

    // #then the operator can recognise the file, and two checkouts of the same
    // project still get different ones
    expect(path.basename(ref.path)).toMatch(new RegExp(`^${path.basename(repo)}-[0-9a-f]{12}\\.json$`));
  });

  test("два разных чекаута → разные baseline-файлы", () => {
    // #given two repositories with the same basename is impossible via mkdtemp,
    // so use two distinct repos and assert the keys do not collide
    const a = makeRepo();
    const b = makeRepo();
    const state = stateDir();

    // #when both are resolved against one state dir
    // #then each repo owns its own baseline
    expect(resolveBaseline(a, { stateDir: state }).path).not.toBe(resolveBaseline(b, { stateDir: state }).path);
  });

  test("файла нет → exists:false; после capture → exists:true", () => {
    // #given a repo never baselined before
    const repo = makeRepo();
    const state = stateDir();
    const before = resolveBaseline(repo, { stateDir: state });
    expect(before.exists).toBe(false);

    // #when a report is captured as the baseline
    const report = path.join(state, "report.json");
    fs.writeFileSync(report, "[]");
    captureBaseline(before.path, report);

    // #then the next resolution sees it
    expect(resolveBaseline(repo, { stateDir: state }).exists).toBe(true);
  });
});

describe("captureBaseline", () => {
  test("создаёт недостающие каталоги и копирует отчёт целиком", () => {
    // #given a state dir that has never held a baseline
    const state = stateDir();
    const report = path.join(state, "report.json");
    const body = JSON.stringify([{ Fingerprint: "a.txt:generic-api-key:1", Description: "d" }]);
    fs.writeFileSync(report, body);
    const target = path.join(state, "secret-baseline", "nested", "repo-abc123456789.json");

    // #when the report is captured
    captureBaseline(target, report);

    // #then the baseline exists with the report's exact contents
    expect(fs.readFileSync(target, "utf8")).toBe(body);
  });
});

describe("readReportFindings", () => {
  test("нормальный отчёт gitleaks → fingerprint и description", () => {
    // #given a gitleaks JSON report
    const dir = stateDir();
    const report = path.join(dir, "r.json");
    fs.writeFileSync(report, JSON.stringify([{ Fingerprint: "sub/creds.txt:aws-access-token:1", Description: "AWS creds" }]));

    // #when it is read
    const findings = readReportFindings(report);

    // #then the fingerprint is available to name the finding
    expect(findings).toEqual([{ fingerprint: "sub/creds.txt:aws-access-token:1", description: "AWS creds" }]);
  });

  test("отчёт без Fingerprint → собирается из File:RuleID:StartLine", () => {
    // #given a report row missing the fingerprint field
    const dir = stateDir();
    const report = path.join(dir, "r.json");
    fs.writeFileSync(report, JSON.stringify([{ File: "a.txt", RuleID: "generic-api-key", StartLine: 7 }]));

    // #when it is read
    const findings = readReportFindings(report);

    // #then the finding is still nameable
    expect(findings[0]?.fingerprint).toBe("a.txt:generic-api-key:7");
  });

  test("пустой отчёт → пустой список", () => {
    // #given a clean scan's report
    const dir = stateDir();
    const report = path.join(dir, "r.json");
    fs.writeFileSync(report, "[]");

    // #when it is read
    // #then nothing is reported
    expect(readReportFindings(report)).toEqual([]);
  });

  test("нечитаемый или битый отчёт → пустой список, без throw", () => {
    // #given a missing file and a truncated one — the exit code, not this
    // function, is what fails the gate closed
    const dir = stateDir();
    const broken = path.join(dir, "broken.json");
    fs.writeFileSync(broken, "[{");

    // #when both are read
    // #then neither throws and the message just loses its names
    expect(readReportFindings(path.join(dir, "no-such.json"))).toEqual([]);
    expect(readReportFindings(broken)).toEqual([]);
  });
});
