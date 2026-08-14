import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  type IssueFields,
  issueFileName,
  nextIssueSequence,
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
