import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  type IssueFields,
  issueFileName,
  nextIssueSequence,
  publishIssue,
  redactSecretsInText,
  renderIssueMarkdown,
  shouldWriteIssue,
  writeIssueFile,
} from "./issue-writer.ts";

function fields(over: Partial<IssueFields> = {}): IssueFields {
  return {
    date: "2026-08-13",
    disposition: "failure",
    title: "Reviewer leg died mid-stream",
    runId: "run-123",
    failedBlock: "code-review",
    cause: "The external review leg exited non-terminal.",
    evidenceArtifacts: ["outcome.json", "review.log"],
    logExcerpts: "leg exited code 137",
    proposedFix: "Raise the idle timeout for the leg.",
    ...over,
  };
}

describe("shouldWriteIssue", () => {
  test("writes on failure and actionable optimization, not on clean success", () => {
    expect(shouldWriteIssue("failure")).toBe(true);
    expect(shouldWriteIssue("actionable-optimization")).toBe(true);
    expect(shouldWriteIssue("clean-success")).toBe(false);
  });
});

describe("nextIssueSequence", () => {
  test("returns the next NNN for the day", () => {
    const existing = ["2026-08-13-001-a.md", "2026-08-13-002-b.md", "2026-08-12-009-c.md", "notes.txt"];
    expect(nextIssueSequence(existing, "2026-08-13")).toBe(3);
  });

  test("starts at 1 for a day with no issues", () => {
    expect(nextIssueSequence(["2026-08-12-004-x.md"], "2026-08-13")).toBe(1);
  });

  test("rejects allocation after sequence 999", () => {
    expect(() => nextIssueSequence(["2026-08-13-999-last.md"], "2026-08-13")).toThrow("sequence exhausted");
  });
});

describe("issueFileName", () => {
  test("pads the sequence and slugs the title", () => {
    expect(issueFileName("2026-08-13", 3, "Reviewer Leg Died!")).toBe("2026-08-13-003-reviewer-leg-died.md");
  });

  test("never formats a four-digit sequence", () => {
    expect(() => issueFileName("2026-08-13", 1000, "Overflow")).toThrow("invalid issue sequence");
  });
});

describe("redactSecretsInText", () => {
  test("redacts an openai key and reports the hit", () => {
    const { redacted, hits } = redactSecretsInText("token is sk-abcdefghijklmnopqrstuvwxyz012345 here");
    expect(redacted).not.toContain("sk-abcdefghijklmnopqrstuvwxyz012345");
    expect(redacted).toContain("[REDACTED]");
    expect(hits).toContain("openai-key");
  });

  test("redacts an assigned secret but keeps the key name", () => {
    const { redacted, hits } = redactSecretsInText('AWS_SECRET_ACCESS_KEY="abc123def456"');
    expect(redacted).toContain("AWS_SECRET_ACCESS_KEY=[REDACTED]");
    expect(redacted).not.toContain("abc123def456");
    expect(hits).toContain("assigned-secret");
  });

  test("leaves ordinary text untouched", () => {
    const { redacted, hits } = redactSecretsInText("the block exhausted its retries");
    expect(redacted).toBe("the block exhausted its retries");
    expect(hits).toHaveLength(0);
  });
});

describe("renderIssueMarkdown", () => {
  test("failure renders machine-consumed issue metadata", () => {
    const md = renderIssueMarkdown(fields());
    expect(md).toContain("status: open");
    expect(md).toContain("run-id: run-123");
  });
});

describe("writeIssueFile", () => {
  test("writes a redacted file with the next sequence in docs/issues", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-test-"));
    const dir = path.join(repo, "docs", "issues");
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "2026-08-13-001-earlier.md"), "x");

    const written = writeIssueFile(repo, fields({ logExcerpts: "leaked sk-abcdefghijklmnopqrstuvwxyz012345" }));
    expect(path.basename(written.path)).toBe("2026-08-13-002-reviewer-leg-died-mid-stream.md");
    expect(written.redactionHits).toContain("openai-key");
    const contents = fs.readFileSync(written.path, "utf8");
    expect(contents).not.toContain("sk-abcdefghijklmnopqrstuvwxyz012345");
    expect(contents).toContain("[REDACTED]");
    expect(fs.statSync(written.path).mode & 0o777).toBe(0o644);
  });

  for (const segment of ["docs", "docs/issues"]) {
    test(`rejects a legacy publication through symlinked ${segment}`, () => {
      const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-test-"));
      const outside = fs.mkdtempSync(path.join(os.tmpdir(), "issue-outside-"));
      const marker = path.join(outside, "marker");
      fs.writeFileSync(marker, "unchanged");
      if (segment === "docs/issues") fs.mkdirSync(path.join(repo, "docs"));
      fs.symlinkSync(outside, path.join(repo, segment));

      expect(() => publishIssue(repo, fields())).toThrow("unsafe issue directory");
      expect(fs.readFileSync(marker, "utf8")).toBe("unchanged");
      expect(fs.readdirSync(outside)).toEqual(["marker"]);
    });
  }

  test("removes its temporary inode when the daily sequence is exhausted", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-test-"));
    const dir = path.join(repo, "docs", "issues");
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "2026-08-13-999-last.md"), "existing");

    expect(() => writeIssueFile(repo, fields())).toThrow("sequence exhausted");
    expect(fs.readdirSync(dir).filter((name) => name.startsWith(".issue-writer-"))).toEqual([]);
    expect(fs.readdirSync(dir)).toEqual(["2026-08-13-999-last.md"]);
  });

  test("publishes concurrent legacy issues at unique canonical paths with complete contents", async () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-test-"));
    const modulePath = new URL("./issue-writer.ts", import.meta.url).href;
    const issueFields = fields({ logExcerpts: "complete marker sk-abcdefghijklmnopqrstuvwxyz012345" });
    const publications = await Promise.all(
      Array.from({ length: 8 }, () => new Promise<{ path: string; mode: string }>((resolve, reject) => {
        const child = spawn(process.execPath, ["-e", `import { publishIssue } from ${JSON.stringify(modulePath)}; console.log(JSON.stringify(publishIssue(${JSON.stringify(repo)}, ${JSON.stringify(issueFields)})));`], {
          stdio: ["ignore", "pipe", "pipe"],
        });
        let stdout = "";
        let stderr = "";
        child.stdout.on("data", (chunk) => { stdout += chunk; });
        child.stderr.on("data", (chunk) => { stderr += chunk; });
        child.on("error", reject);
        child.on("close", (code) => {
          if (code !== 0) reject(new Error(stderr || `child exited ${code}`));
          else resolve(JSON.parse(stdout));
        });
      })),
    );

    expect(new Set(publications.map((publication) => publication.path)).size).toBe(publications.length);
    for (const publication of publications) {
      expect(publication.mode).toBe("legacy");
      expect(path.relative(fs.realpathSync(repo), publication.path)).toMatch(/^docs\/issues\/2026-08-13-\d{3}-reviewer-leg-died-mid-stream\.md$/);
      const contents = fs.readFileSync(publication.path, "utf8");
      expect(contents).toContain("complete marker [REDACTED]");
      expect(contents).toContain("Launching any fix stays the operator's decision.\n");
    }
    expect(fs.readdirSync(path.join(repo, "docs", "issues")).filter((name) => name.startsWith(".issue-writer-"))).toEqual([]);
  });
});

describe("publishIssue", () => {
  test("retries the real CLI idempotently by run ID", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    fs.mkdirSync(path.join(repo, ".git"));
    fs.mkdirSync(path.join(repo, "scripts"));
    fs.copyFileSync(path.resolve(import.meta.dir, "../../../../../scripts/issues"), path.join(repo, "scripts", "issues"));
    fs.chmodSync(path.join(repo, "scripts", "issues"), 0o755);

    const first = publishIssue(repo, fields());
    const second = publishIssue(repo, fields());

    expect(first.mode).toBe("cli");
    expect(second).toEqual(first);
    expect(fs.readdirSync(path.join(repo, "docs", "issues")).filter((name) => name.endsWith(".md"))).toHaveLength(1);
  });

  test("delegates a redacted issue to a compatible target CLI without directly writing files", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(
      path.join(scripts, "issues"),
      `#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'repository-issues-contract 2\\n'
  exit 0
fi
printf '%s\\n' "$@" > "$PWD/received-arguments"
mkdir -p "$PWD/docs/issues"
printf '%s\\n' '---' 'external-id: "run-123"' '---' > "$PWD/docs/issues/2026-08-13-001-reviewer-leg-died-mid-stream.md"
printf 'docs/issues/2026-08-13-001-reviewer-leg-died-mid-stream.md\\n'
`,
      { mode: 0o755 },
    );

    const result = publishIssue(repo, fields({ logExcerpts: "leaked sk-abcdefghijklmnopqrstuvwxyz012345" }));

    expect(result.mode).toBe("cli");
    expect(result.path).toBe(path.join(repo, "docs/issues/2026-08-13-001-reviewer-leg-died-mid-stream.md"));
    expect(result.redactionHits).toContain("openai-key");
    const received = fs.readFileSync(path.join(repo, "received-arguments"), "utf8");
    expect(received).toContain("--category\nse-pipeline\n--tag\nsmithers\n");
    expect(received).toContain("--external-id\nrun-123\n");
    expect(received).toContain("--priority\nhigh\n");
    expect(received).toContain("Run ID: run-123\nFailed block: code-review\n");
    expect(received).not.toContain("sk-abcdefghijklmnopqrstuvwxyz012345");
  });

  test("uses the legacy writer when the target CLI is absent", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));

    const result = publishIssue(repo, fields());

    expect(result.mode).toBe("legacy");
    expect(fs.existsSync(result.path!)).toBe(true);
  });

  test("fails closed without writing when the target CLI contract does not match", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(path.join(scripts, "issues"), "#!/bin/sh\nprintf 'repository-issues-contract 1\\n'\n", { mode: 0o755 });

    const result = publishIssue(repo, fields({ logExcerpts: "leaked sk-abcdefghijklmnopqrstuvwxyz012345" }));

    expect(result.mode).toBe("cli-failed");
    expect(result.path).toBeNull();
    expect(result.error).toContain("incompatible contract");
    expect(fs.existsSync(path.join(repo, "docs", "issues"))).toBe(false);
  });

  test("does not use the legacy writer when the target CLI version probe exits nonzero", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(path.join(scripts, "issues"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });

    const result = publishIssue(repo, fields());

    expect(result.mode).toBe("cli-failed");
    expect(result.path).toBeNull();
    expect(fs.existsSync(path.join(repo, "docs", "issues"))).toBe(false);
  });

  test("does not use the legacy writer when the target CLI cannot execute", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(path.join(scripts, "issues"), "#!/bin/sh\nexit 0\n", { mode: 0o644 });

    const result = publishIssue(repo, fields());

    expect(result.mode).toBe("cli-failed");
    expect(result.path).toBeNull();
    expect(result.error).toContain("EACCES");
    expect(fs.existsSync(path.join(repo, "docs", "issues"))).toBe(false);
  });

  test(
    "fails closed when the target CLI version probe times out",
    () => {
      const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
      const scripts = path.join(repo, "scripts");
      fs.mkdirSync(scripts, { recursive: true });
      fs.writeFileSync(path.join(scripts, "issues"), "#!/bin/sh\nexec sleep 10\n", { mode: 0o755 });

      // Deliberately no injected timeout: this is the one test proving the
      // production default (ISSUE_CLI_TIMEOUT_MS) is wired and finite
      // against a hung CLI. It costs ~5s of wall clock by design.
      const result = publishIssue(repo, fields());

      expect(result.mode).toBe("cli-failed");
      expect(result.path).toBeNull();
      expect(result.error).toContain("ETIMEDOUT");
      expect(fs.existsSync(path.join(repo, "docs", "issues"))).toBe(false);
    },
    7_000,
  );

  test("records a compatible CLI publication failure without a legacy direct-write fallback", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(
      path.join(scripts, "issues"),
      `#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'repository-issues-contract 2\\n'
  exit 0
fi
printf 'creation refused\\n' >&2
exit 2
`,
      { mode: 0o755 },
    );

    const result = publishIssue(repo, fields());

    expect(result.mode).toBe("cli-failed");
    expect(result.path).toBeNull();
    expect(result.error).toContain("creation refused");
    expect(fs.existsSync(path.join(repo, "docs", "issues"))).toBe(false);
  });

  test("rejects a successful CLI publication without the matching external ID", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(
      path.join(scripts, "issues"),
      `#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'repository-issues-contract 2\\n'
  exit 0
fi
mkdir -p "$PWD/docs/issues"
printf '%s\\n' '---' 'external-id: "another-run"' '---' > "$PWD/docs/issues/2026-08-13-001-wrong-request.md"
printf 'docs/issues/2026-08-13-001-wrong-request.md\\n'
`,
      { mode: 0o755 },
    );

    const result = publishIssue(repo, fields());

    expect(result.mode).toBe("cli-failed");
    expect(result.path).toBeNull();
    expect(result.error).toContain("invalid or nonexistent issue path");
  });

  test(
    "fails closed when compatible CLI creation times out",
    () => {
      const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
      const scripts = path.join(repo, "scripts");
      fs.mkdirSync(scripts, { recursive: true });
      fs.writeFileSync(
        path.join(scripts, "issues"),
        `#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'repository-issues-contract 2\\n'
  exit 0
fi
exec sleep 10
`,
        { mode: 0o755 },
      );

      // Same injected-timeout rationale as the version-probe test above.
      const result = publishIssue(repo, fields(), 300);

      expect(result.mode).toBe("cli-failed");
      expect(result.path).toBeNull();
      expect(result.error).toContain("ETIMEDOUT");
      expect(fs.existsSync(path.join(repo, "docs", "issues"))).toBe(false);
    },
  );

  for (const [name, output, createTarget] of [
    ["empty", "", ""],
    ["malformed", "docs/issues/issue.md\\ndocs/issues/second.md\\n", "docs/issues/issue.md"],
    ["outside", "other/issue.md\\n", "other/issue.md"],
    ["noncanonical", "docs/issues/not-an-issue.md\\n", "docs/issues/not-an-issue.md"],
    ["nonexistent", "docs/issues/missing.md\\n", ""],
  ] as const) {
    test(`rejects ${name} successful CLI stdout`, () => {
      const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
      const scripts = path.join(repo, "scripts");
      fs.mkdirSync(scripts, { recursive: true });
      fs.writeFileSync(
        path.join(scripts, "issues"),
        `#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'repository-issues-contract 2\\n'
  exit 0
fi
${createTarget ? `mkdir -p "$(dirname "$PWD/${createTarget}")"\ntouch "$PWD/${createTarget}"` : ""}
printf '${output}'
`,
        { mode: 0o755 },
      );

      const result = publishIssue(repo, fields());

      expect(result.mode).toBe("cli-failed");
      expect(result.path).toBeNull();
      expect(result.error).toContain("invalid or nonexistent issue path");
    });
  }

  test("rejects a publication through a symlinked docs/issues directory", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    const outside = fs.mkdtempSync(path.join(os.tmpdir(), "issue-outside-"));
    fs.mkdirSync(scripts, { recursive: true });
    fs.mkdirSync(path.join(repo, "docs"));
    fs.symlinkSync(outside, path.join(repo, "docs", "issues"));
    fs.writeFileSync(
      path.join(scripts, "issues"),
      `#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'repository-issues-contract 2\\n'
  exit 0
fi
touch "$PWD/docs/issues/2026-08-13-001-escaped.md"
printf 'docs/issues/2026-08-13-001-escaped.md\\n'
`,
      { mode: 0o755 },
    );

    const result = publishIssue(repo, fields());

    expect(result.mode).toBe("cli-failed");
    expect(result.path).toBeNull();
  });

  test("rejects a returned issue file that is a symlink", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    const issues = path.join(repo, "docs", "issues");
    const outside = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "issue-outside-")), "target.md");
    fs.mkdirSync(scripts, { recursive: true });
    fs.mkdirSync(issues, { recursive: true });
    fs.writeFileSync(outside, "outside");
    fs.symlinkSync(outside, path.join(issues, "2026-08-13-001-symlink.md"));
    fs.writeFileSync(
      path.join(scripts, "issues"),
      `#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'repository-issues-contract 2\\n'
  exit 0
fi
printf 'docs/issues/2026-08-13-001-symlink.md\\n'
`,
      { mode: 0o755 },
    );

    const result = publishIssue(repo, fields());

    expect(result.mode).toBe("cli-failed");
    expect(result.path).toBeNull();
  });

  test("uses medium priority for actionable optimizations", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(
      path.join(scripts, "issues"),
      `#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'repository-issues-contract 2\\n'
  exit 0
fi
printf '%s\\n' "$@" > "$PWD/received-arguments"
mkdir -p "$PWD/docs/issues"
printf '%s\\n' '---' 'external-id: "run-123"' '---' > "$PWD/docs/issues/2026-08-21-001-optimization.md"
printf 'docs/issues/2026-08-21-001-optimization.md\\n'
`,
      { mode: 0o755 },
    );

    publishIssue(repo, fields({ disposition: "actionable-optimization" }));

    expect(fs.readFileSync(path.join(repo, "received-arguments"), "utf8")).toContain("--priority\nmedium\n");
  });

  test("redacts every issue field before passing values to the target CLI", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(
      path.join(scripts, "issues"),
      `#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'repository-issues-contract 2\\n'
  exit 0
fi
printf '%s\\n' "$@" > "$PWD/received-arguments"
mkdir -p "$PWD/docs/issues"
printf '%s\\n' '---' 'external-id: "[REDACTED]"' '---' > "$PWD/docs/issues/2026-08-21-001-redacted.md"
printf 'docs/issues/2026-08-21-001-redacted.md\\n'
`,
      { mode: 0o755 },
    );
    const secret = "sk-abcdefghijklmnopqrstuvwxyz012345";

    const result = publishIssue(
      repo,
      fields({ title: secret, runId: secret, failedBlock: secret, cause: secret, evidenceArtifacts: [secret], logExcerpts: secret, proposedFix: secret }),
    );

    expect(result.mode).toBe("cli");
    expect(fs.readFileSync(path.join(repo, "received-arguments"), "utf8")).not.toContain(secret);
    expect(result.redactionHits.length).toBeGreaterThanOrEqual(7);
  });
});

describe("redactSecretsInText inside JSON log payloads", () => {
  test("stops the redaction at an escaped newline instead of eating the next line", () => {
    // #given a payload where the secret is followed by a JSON-escaped newline
    const payload = String.raw`{"output":"AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE\n\nbun test v1.3.14"}`;

    // #when it is redacted
    const { redacted } = redactSecretsInText(payload);

    // #then the key is gone and the following log line survives
    expect(redacted).not.toContain("AKIAIOSFODNN7EXAMPLE");
    expect(redacted).toContain("bun test v1.3.14");
  });
});
