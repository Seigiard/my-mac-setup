import { describe, expect, test } from "bun:test";
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
});

describe("issueFileName", () => {
  test("pads the sequence and slugs the title", () => {
    expect(issueFileName("2026-08-13", 3, "Reviewer Leg Died!")).toBe("2026-08-13-003-reviewer-leg-died.md");
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
  test("failure renders cause-analysis with the failed block", () => {
    const md = renderIssueMarkdown(fields());
    expect(md).toContain("## Cause analysis");
    expect(md).toContain("**Failed block:** `code-review`");
    expect(md).toContain("status: open");
    expect(md).toContain("run-id: run-123");
  });

  test("actionable optimization renders the optimization heading", () => {
    const md = renderIssueMarkdown(fields({ disposition: "actionable-optimization", failedBlock: undefined }));
    expect(md).toContain("## Optimization opportunity");
    expect(md).not.toContain("Failed block");
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
  });
});

describe("publishIssue", () => {
  test("delegates a redacted issue to a compatible target CLI without directly writing files", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(
      path.join(scripts, "issues"),
      `#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'repository-issues-contract 1\\n'
  exit 0
fi
printf '%s\\n' "$@" > "$PWD/received-arguments"
printf 'docs/issues/2026-08-13-001-reviewer-leg-died-mid-stream.md\\n'
`,
      { mode: 0o755 },
    );

    const result = publishIssue(repo, fields({ logExcerpts: "leaked sk-abcdefghijklmnopqrstuvwxyz012345" }));

    expect(result.mode).toBe("cli");
    expect(result.path).toBe(path.join(repo, "docs/issues/2026-08-13-001-reviewer-leg-died-mid-stream.md"));
    expect(result.redactionHits).toContain("openai-key");
    expect(fs.existsSync(path.join(repo, "docs", "issues"))).toBe(false);
    const received = fs.readFileSync(path.join(repo, "received-arguments"), "utf8");
    expect(received).toContain("--category\nse-pipeline\n--tag\nsmithers\n--priority\nhigh\n");
    expect(received).not.toContain("sk-abcdefghijklmnopqrstuvwxyz012345");
  });

  test("uses the legacy writer when the target CLI contract does not match", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(path.join(scripts, "issues"), "#!/bin/sh\nprintf 'repository-issues-contract 2\\n'\n", { mode: 0o755 });

    const result = publishIssue(repo, fields({ logExcerpts: "leaked sk-abcdefghijklmnopqrstuvwxyz012345" }));

    expect(result.mode).toBe("legacy");
    expect(result.redactionHits).toContain("openai-key");
    expect(fs.readFileSync(result.path, "utf8")).not.toContain("sk-abcdefghijklmnopqrstuvwxyz012345");
  });

  test("uses the legacy writer when the target CLI version probe exits nonzero", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(path.join(scripts, "issues"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });

    const result = publishIssue(repo, fields());

    expect(result.mode).toBe("legacy");
    expect(fs.existsSync(result.path)).toBe(true);
  });

  test("records a compatible CLI publication failure without a legacy direct-write fallback", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(
      path.join(scripts, "issues"),
      `#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'repository-issues-contract 1\\n'
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

  test("uses medium priority for actionable optimizations", () => {
    const repo = fs.mkdtempSync(path.join(os.tmpdir(), "issue-target-"));
    const scripts = path.join(repo, "scripts");
    fs.mkdirSync(scripts, { recursive: true });
    fs.writeFileSync(
      path.join(scripts, "issues"),
      `#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'repository-issues-contract 1\\n'
  exit 0
fi
printf '%s\\n' "$@" > "$PWD/received-arguments"
`,
      { mode: 0o755 },
    );

    publishIssue(repo, fields({ disposition: "actionable-optimization" }));

    expect(fs.readFileSync(path.join(repo, "received-arguments"), "utf8")).toContain("--priority\nmedium\n");
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
