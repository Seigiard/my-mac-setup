// Reviewer issue writer (R15/KTD10/KTD13). Turns a terminal-review disposition
// into a triageable docs/issues/ file — but only on failure or an actionable
// optimization; a clean-success review lives in the outcome record with no file
// (R15). The filename follows the repo's existing convention
// (YYYY-MM-DD-NNN-<slug>.md) and every byte of issue text passes a
// publication-time secret redaction before it is written (KTD13(b)), so a secret
// captured in a log excerpt is never copied into a durable store.
import * as fs from "node:fs";
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
  return max + 1;
}

export function issueFileName(date: string, seq: number, slug: string): string {
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
// any redaction hits (surfaced in the reviewer output, KTD13). The caller passes
// the existing filenames so sequencing stays a pure decision; this function does
// the single fs read of the directory only to keep the write atomic-ish.
export function writeIssueFile(repoRoot: string, fields: IssueFields): WrittenIssue {
  const dir = path.join(repoRoot, "docs", "issues");
  fs.mkdirSync(dir, { recursive: true });
  const existing = fs.readdirSync(dir);
  const seq = nextIssueSequence(existing, fields.date);
  const name = issueFileName(fields.date, seq, fields.title);
  const rendered = renderIssueMarkdown(fields);
  const { redacted, hits } = redactSecretsInText(rendered);
  const filePath = path.join(dir, name);
  fs.writeFileSync(filePath, redacted);
  return { path: filePath, redactionHits: hits };
}
