// Reviewer issue writer (R15/KTD10/KTD13). Turns a terminal-review disposition
// into a triageable docs/issues/ file — but only on failure or an actionable
// optimization; a clean-success review lives in the outcome record with no file
// (R15). The filename follows the repo's existing convention
// (YYYY-MM-DD-NNN-<slug>.md) and every byte of issue text passes a
// publication-time secret redaction before it is written (KTD13(b)), so a secret
// captured in a log excerpt is never copied into a durable store.
import * as fs from "node:fs";
import { spawnSync } from "node:child_process";
import * as path from "node:path";

import { slugify } from "./staging.ts";

export type ReviewDisposition = "failure" | "actionable-optimization" | "clean-success";

export interface IssueFields {
  date: string;
  disposition: ReviewDisposition;
  title: string;
  runId: string;
  parentPlan?: string;
  failedBlock?: string;
  cause: string;
  evidenceArtifacts: string[];
  logExcerpts: string;
  proposedFix: string;
}

export interface RedactionResult {
  redacted: string;
  hits: string[];
}

export interface WrittenIssue {
  path: string;
  redactionHits: string[];
}

export interface PublishedIssue {
  mode: "legacy" | "cli" | "cli-failed";
  path: string | null;
  redactionHits: string[];
  error?: string;
}

// R15: an issue file is written for a failure or an actionable optimization; a
// clean success is recorded elsewhere.
export function shouldWriteIssue(disposition: ReviewDisposition): boolean {
  return disposition === "failure" || disposition === "actionable-optimization";
}

const ISSUE_FILE = /^(\d{4}-\d{2}-\d{2})-(\d{3})-.+\.md$/;

// Next NNN for the day: max existing sequence for `date` plus one, 1-based.
export function nextIssueSequence(existingFilenames: string[], date: string): number {
  let max = 0;
  for (const name of existingFilenames) {
    const m = ISSUE_FILE.exec(name);
    if (m && m[1] === date) {
      const seq = Number.parseInt(m[2], 10);
      if (seq > max) max = seq;
    }
  }
  if (max >= 999) throw new Error(`issue sequence exhausted for ${date}`);
  return max + 1;
}

export function issueFileName(date: string, seq: number, slug: string): string {
  if (!Number.isInteger(seq) || seq < 1 || seq > 999) throw new Error(`invalid issue sequence: ${seq}`);
  return `${date}-${String(seq).padStart(3, "0")}-${slugify(slug)}.md`;
}

// High-signal secret shapes for publication-time text scanning (KTD13(b)). This
// is a text redactor, distinct from the diff-scoped gitleaks scan (envelopes.ts)
// — the reviewer's inputs (outcome record, log excerpts, PR body) are strings,
// not a git range. Patterns are deliberately conservative: a real credential
// shape, not every high-entropy token, so normal log text is not mangled.
const SECRET_PATTERNS: Array<{ label: string; re: RegExp }> = [
  { label: "private-key-block", re: /-----BEGIN[ A-Z]*PRIVATE KEY-----[\s\S]*?-----END[ A-Z]*PRIVATE KEY-----/g },
  { label: "openai-key", re: /\bsk-[A-Za-z0-9_-]{20,}\b/g },
  { label: "github-token", re: /\bgh[posru]_[A-Za-z0-9]{20,}\b/g },
  { label: "aws-access-key", re: /\bAKIA[0-9A-Z]{16}\b/g },
  { label: "slack-token", re: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g },
  { label: "bearer-token", re: /\bBearer\s+[A-Za-z0-9._-]{20,}\b/g },
  // The value stops at a backslash as well as at whitespace: log excerpts are
  // JSON payloads where a newline is the two characters \n, not whitespace, so
  // without it one assignment swallowed the rest of the line (observed live in
  // run-1786704594258, which ate "bun" from a test summary). Real secrets carry
  // no backslash, so the boundary costs no coverage.
  { label: "assigned-secret", re: /\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|API_KEY|APIKEY|ACCESS_KEY)[A-Z0-9_]*)\s*[=:]\s*['"]?[^\s'"\\]{6,}/g },
];

export function redactSecretsInText(text: string): RedactionResult {
  let redacted = text;
  const hits: string[] = [];
  for (const { label, re } of SECRET_PATTERNS) {
    redacted = redacted.replace(re, (_match, capture) => {
      hits.push(label);
      // Assigned secrets keep the key name so the redaction stays legible.
      if (label === "assigned-secret" && typeof capture === "string") return `${capture}=[REDACTED]`;
      return "[REDACTED]";
    });
  }
  return { redacted, hits };
}

export function renderIssueMarkdown(fields: IssueFields): string {
  const artifacts = fields.evidenceArtifacts.length > 0 ? fields.evidenceArtifacts.map((a) => `- ${a}`).join("\n") : "- (none recorded)";
  const heading = fields.disposition === "failure" ? "Cause analysis" : "Optimization opportunity";
  const body = `---
title: ${fields.title}
type: follow-up
date: ${fields.date}
status: open${fields.parentPlan ? `\nparent-plan: ${fields.parentPlan}` : ""}
run-id: ${fields.runId}
---

# ${fields.title}

## ${heading}

${fields.cause}
${fields.failedBlock ? `\n**Failed block:** \`${fields.failedBlock}\`\n` : ""}
## Evidence artifacts

${artifacts}

## Log excerpts

\`\`\`
${fields.logExcerpts}
\`\`\`

## Proposed fix

${fields.proposedFix}

Launching any fix stays the operator's decision.
`;
  return body;
}

// Writes the issue file under `<repoRoot>/docs/issues/`, returning its path and
// any redaction hits (surfaced in the reviewer output, KTD13). A fully synced
// temporary file is hard-linked into place so concurrent writers cannot replace
// one another's publication.
export function writeIssueFile(repoRoot: string, fields: IssueFields): WrittenIssue {
  const realRepoRoot = fs.realpathSync(repoRoot);
  let dir = realRepoRoot;
  for (const segment of ["docs", "issues"]) {
    const candidate = path.join(dir, segment);
    try {
      fs.mkdirSync(candidate);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    }
    const stat = fs.lstatSync(candidate);
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error(`unsafe issue directory: ${candidate}`);
    const realCandidate = fs.realpathSync(candidate);
    if (!isContainedPath(realRepoRoot, realCandidate)) throw new Error(`issue directory escapes repository: ${candidate}`);
    dir = realCandidate;
  }
  const rendered = renderIssueMarkdown(fields);
  const { redacted, hits } = redactSecretsInText(rendered);
  let temporaryPath: string | null = null;
  let temporaryFd: number | null = null;

  try {
    for (let attempt = 0; ; attempt += 1) {
      temporaryPath = path.join(dir, `.issue-writer-${process.pid}-${Date.now()}-${attempt}.tmp`);
      try {
        temporaryFd = fs.openSync(temporaryPath, "wx", 0o644);
        fs.fchmodSync(temporaryFd, 0o644);
        break;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      }
    }

    fs.writeFileSync(temporaryFd, redacted);
    fs.fsyncSync(temporaryFd);
    fs.closeSync(temporaryFd);
    temporaryFd = null;
    const completedTemporaryPath = temporaryPath;
    if (completedTemporaryPath === null) throw new Error("issue writer temporary file was not created");

    let seq = nextIssueSequence(fs.readdirSync(dir), fields.date);
    for (;;) {
      const filePath = path.join(dir, issueFileName(fields.date, seq, fields.title));
      try {
        fs.linkSync(completedTemporaryPath, filePath);
        fs.unlinkSync(completedTemporaryPath);
        temporaryPath = null;
        const dirFd = fs.openSync(dir, "r");
        try {
          fs.fsyncSync(dirFd);
        } finally {
          fs.closeSync(dirFd);
        }
        return { path: filePath, redactionHits: hits };
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        seq += 1;
        if (seq > 999) throw new Error(`issue sequence exhausted for ${fields.date}`);
      }
    }
  } finally {
    if (temporaryFd !== null) fs.closeSync(temporaryFd);
    if (temporaryPath !== null) {
      try {
        fs.unlinkSync(temporaryPath);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
  }
}

const ISSUE_CLI_CONTRACT = "repository-issues-contract 2\n";
const ISSUE_CLI_TIMEOUT_MS = 5_000;

function redactedFields(fields: IssueFields): { fields: IssueFields; hits: string[] } {
  const hits: string[] = [];
  const redact = (value: string | undefined): string | undefined => {
    if (value === undefined) return undefined;
    const result = redactSecretsInText(value);
    hits.push(...result.hits);
    return result.redacted;
  };
  return {
    fields: {
      ...fields,
      title: redact(fields.title)!,
      runId: redact(fields.runId)!,
      parentPlan: redact(fields.parentPlan),
      failedBlock: redact(fields.failedBlock),
      cause: redact(fields.cause)!,
      evidenceArtifacts: fields.evidenceArtifacts.map((artifact) => redact(artifact)!),
      logExcerpts: redact(fields.logExcerpts)!,
      proposedFix: redact(fields.proposedFix)!,
    },
    hits,
  };
}

function shortDescription(fields: IssueFields): string {
  const prefix = fields.disposition === "failure" ? "Pipeline failure: " : "Pipeline optimization: ";
  return `${prefix}${fields.title}`.slice(0, 240);
}

function cliFailure(redactionHits: string[], message: string): PublishedIssue {
  const failure = redactSecretsInText(message);
  return {
    mode: "cli-failed",
    path: null,
    redactionHits: [...redactionHits, ...failure.hits],
    error: failure.redacted,
  };
}

function spawnFailureMessage(operation: string, result: { stderr: string | Buffer | null; error?: Error; status: number | null }): string {
  return `${result.stderr ?? ""}${result.error ? String(result.error) : ""}`.trim() || `scripts/issues ${operation} exited ${result.status ?? "without a status"}`;
}

function isContainedPath(parent: string, child: string): boolean {
  const relative = path.relative(parent, child);
  return Boolean(relative) && relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function validatePublishedPath(repoRoot: string, stdout: string | Buffer, externalId: string): string | null {
  const rawOutput = String(stdout);
  const relativePath = rawOutput.endsWith("\n") ? rawOutput.slice(0, -1) : rawOutput;
  const pathParts = relativePath.split("/");
  if (
    !relativePath ||
    relativePath.trim() !== relativePath ||
    relativePath.includes("\n") ||
    relativePath.includes("\r") ||
    relativePath.includes("\\") ||
    path.isAbsolute(relativePath) ||
    pathParts.length !== 3 ||
    pathParts[0] !== "docs" ||
    pathParts[1] !== "issues" ||
    !ISSUE_FILE.test(pathParts[2])
  ) {
    return null;
  }

  const issuesDir = path.join(repoRoot, "docs", "issues");
  const publishedPath = path.resolve(repoRoot, relativePath);

  try {
    const realRepoRoot = fs.realpathSync(repoRoot);
    if (fs.lstatSync(path.join(repoRoot, "docs")).isSymbolicLink()) return null;
    if (fs.lstatSync(issuesDir).isSymbolicLink()) return null;
    const publishedStat = fs.lstatSync(publishedPath);
    if (publishedStat.isSymbolicLink() || !publishedStat.isFile()) return null;
    const realIssuesDir = fs.realpathSync(issuesDir);
    const realPublishedPath = fs.realpathSync(publishedPath);
    const fileFromIssues = path.relative(realIssuesDir, realPublishedPath);
    if (
      !isContainedPath(realRepoRoot, realIssuesDir) ||
      !fileFromIssues ||
      fileFromIssues.includes(path.sep) ||
      fileFromIssues === ".." ||
      path.isAbsolute(fileFromIssues)
    ) return null;
    const contents = fs.readFileSync(realPublishedPath, "utf8");
    const frontmatterEnd = contents.indexOf("\n---\n", 4);
    if (
      !contents.startsWith("---\n") ||
      frontmatterEnd < 0 ||
      !contents.slice(4, frontmatterEnd).split("\n").includes(`external-id: ${JSON.stringify(externalId)}`)
    ) return null;
  } catch {
    return null;
  }

  return publishedPath;
}

// The target checkout owns issue creation when it advertises the pinned contract.
// Once that compatible CLI fails, do not bypass its validation and locking with a
// legacy direct write.
export function publishIssue(repoRoot: string, fields: IssueFields, timeoutMs: number = ISSUE_CLI_TIMEOUT_MS): PublishedIssue {
  const cliPath = path.join(repoRoot, "scripts", "issues");
  try {
    fs.lstatSync(cliPath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      const written = writeIssueFile(repoRoot, fields);
      return { mode: "legacy", path: written.path, redactionHits: written.redactionHits };
    }
    return cliFailure([], `Could not inspect scripts/issues: ${String(error)}`);
  }

  const probe = spawnSync(cliPath, ["--version"], { cwd: repoRoot, encoding: "utf8", timeout: timeoutMs, killSignal: "SIGKILL" });
  if (probe.error || probe.status !== 0) return cliFailure([], spawnFailureMessage("--version", probe));
  if (probe.stdout !== ISSUE_CLI_CONTRACT) return cliFailure([], "scripts/issues --version returned an incompatible contract");

  const redacted = redactedFields(fields);
  const why = [`Run ID: ${redacted.fields.runId}`];
  if (redacted.fields.failedBlock) why.push(`Failed block: ${redacted.fields.failedBlock}`);
  why.push("", redacted.fields.cause);
  const args = [
    "create",
    "--title",
    redacted.fields.title,
    "--short-description",
    shortDescription(redacted.fields),
    "--type",
    "follow-up",
    "--category",
    "se-pipeline",
    "--tag",
    "smithers",
    "--external-id",
    redacted.fields.runId,
    "--priority",
    redacted.fields.disposition === "failure" ? "high" : "medium",
    "--why",
    why.join("\n"),
    "--scope",
    `${redacted.fields.proposedFix}\n\nEvidence artifacts:\n${redacted.fields.evidenceArtifacts.map((artifact) => `- ${artifact}`).join("\n")}\n\nLog excerpts:\n${redacted.fields.logExcerpts}`,
    "--open-decisions",
    "None.",
  ];
  if (redacted.fields.parentPlan) args.push("--parent-plan", redacted.fields.parentPlan);

  const published = spawnSync(cliPath, args, { cwd: repoRoot, encoding: "utf8", timeout: timeoutMs, killSignal: "SIGKILL" });
  if (published.error || published.status !== 0) {
    return cliFailure(redacted.hits, spawnFailureMessage("create", published));
  }

  const publishedPath = validatePublishedPath(repoRoot, published.stdout ?? "", redacted.fields.runId);
  if (!publishedPath) return cliFailure(redacted.hits, "scripts/issues create returned an invalid or nonexistent issue path");
  return {
    mode: "cli",
    path: publishedPath,
    redactionHits: redacted.hits,
  };
}
