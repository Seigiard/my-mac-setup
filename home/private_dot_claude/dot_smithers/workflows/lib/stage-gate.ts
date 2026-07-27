// Right-sizing gate for the simplify stage (R14/KTD-I). Pure decision, no LLM
// and no I/O — the caller runs `git diff --numstat base..HEAD`, parses it here,
// and asks whether the diff is worth a simplify pass. The bias is deliberately
// SKIP WHEN UNSURE (the inverse of the review stages' run-when-unsure): a wrong
// skip only leaves code untidy, while a wrong run auto-mutates and costs. When
// neither a clear-skip nor a clear-run rule fires, the result is `inconclusive`
// and the workflow may consult a cheap classifier (Haiku) that keeps the same
// skip-when-unsure bias.
//
// Skip taxonomy mirrors ce-simplify-code's own preflight: empty diff, or a diff
// that is only documentation, generated, vendored, lockfile, or binary churn —
// none of which the reuse/quality/efficiency reviewers can yield on. Mechanical
// (formatting/rename) churn is NOT decided here: `git diff --numstat` carries no
// content, so a rename or reformat is indistinguishable from a real edit by
// line counts alone — that call belongs to the content-aware classifier, and a
// pure rename surfaces here as a normal (often small) substantive diff → most
// often `inconclusive`, which the classifier then skips.

export interface DiffFileStat {
  path: string;
  linesChanged: number;
  binary: boolean;
}

export interface SimplifyGateResult {
  run: boolean;
  reason: string;
  inconclusive: boolean;
}

export type SimplifyStageStatus = "ok" | "skipped" | "degraded";

export interface SimplifyCommitDecision {
  commit: boolean;
  rescan: boolean;
}

// A substantive diff at or above this many executable-code lines clearly earns
// a simplify pass. Below it (but non-empty) the deterministic rule is
// inconclusive and defers to the classifier.
const SUBSTANTIVE_RUN_THRESHOLD = 20;

function isDoc(path: string): boolean {
  return /\.(md|markdown|mdx|txt|rst|adoc)$/i.test(path) || /(^|\/)docs?\//i.test(path);
}

function isLockfile(path: string): boolean {
  const base = path.split("/").pop() ?? path;
  const known = new Set([
    "bun.lock",
    "bun.lockb",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "cargo.lock",
    "poetry.lock",
    "gemfile.lock",
    "go.sum",
    "composer.lock",
    "flake.lock",
  ]);
  return known.has(base.toLowerCase()) || /\.lock$/i.test(base);
}

function isGenerated(path: string): boolean {
  return (
    /\.(min\.js|min\.css|map)$/i.test(path) ||
    /(^|\/)(dist|build|out|\.next|coverage|__snapshots__|generated)\//i.test(path) ||
    /\.(pb\.go|g\.dart)$/i.test(path) ||
    /_pb2\.py$/i.test(path)
  );
}

function isVendored(path: string): boolean {
  return /(^|\/)(node_modules|vendor|third_party|\.venv|venv)\//i.test(path);
}

// A file the simplify reviewers cannot yield on — excluded from the substantive
// line count that decides run/skip.
export function isNoYield(file: DiffFileStat): boolean {
  return file.binary || isDoc(file.path) || isLockfile(file.path) || isGenerated(file.path) || isVendored(file.path);
}

// Parse `git diff --numstat <base>..HEAD`. Each line is
// `<added>\t<deleted>\t<path>`; binary files show `-` for both counts. Rename
// entries (`{old => new}` or `old => new` in the path column) keep the path as
// git prints it and are classified by that text. Tolerant: blank/short lines
// are skipped, never thrown on.
export function parseNumstat(output: string): DiffFileStat[] {
  const files: DiffFileStat[] = [];
  for (const line of output.split("\n")) {
    const trimmed = line.trim();
    if (trimmed === "") continue;
    const parts = trimmed.split("\t");
    if (parts.length < 3) continue;
    const [added, deleted, ...rest] = parts;
    const path = rest.join("\t");
    const binary = added === "-" || deleted === "-";
    const linesChanged = binary ? 0 : (Number.parseInt(added, 10) || 0) + (Number.parseInt(deleted, 10) || 0);
    files.push({ path, linesChanged, binary });
  }
  return files;
}

export function shouldRunSimplify(files: DiffFileStat[]): SimplifyGateResult {
  if (files.length === 0) {
    return { run: false, reason: "empty diff — nothing changed to simplify", inconclusive: false };
  }
  const substantive = files.filter((f) => !isNoYield(f));
  if (substantive.length === 0) {
    return { run: false, reason: `no-yield diff — only ${describeCategories(files)} changed; the simplify reviewers have no code to work on`, inconclusive: false };
  }
  const substantiveLines = substantive.reduce((sum, f) => sum + f.linesChanged, 0);
  if (substantiveLines >= SUBSTANTIVE_RUN_THRESHOLD) {
    return { run: true, reason: `${substantiveLines} executable-code lines across ${substantive.length} file(s) — worth a simplify pass`, inconclusive: false };
  }
  return {
    run: false,
    reason: `borderline: ${substantiveLines} executable-code line(s) across ${substantive.length} file(s), below the ${SUBSTANTIVE_RUN_THRESHOLD}-line clear-run threshold — defer to the classifier`,
    inconclusive: true,
  };
}

function describeCategories(files: DiffFileStat[]): string {
  const cats = new Set<string>();
  for (const f of files) {
    if (f.binary) cats.add("binary");
    else if (isDoc(f.path)) cats.add("docs");
    else if (isLockfile(f.path)) cats.add("lockfile");
    else if (isGenerated(f.path)) cats.add("generated");
    else if (isVendored(f.path)) cats.add("vendored");
  }
  return [...cats].sort().join("/") || "no-code";
}

// Whether the pipeline commits + rescans the simplify stage's output (R9). Only
// an `ok` run that actually applied edits produces a commit to rescan; a
// `skipped` run (gate) or a `degraded` run (apply reverted, or zero legs) leaves
// no new content, so the pipeline commits and rescans nothing and verify-code
// runs on the work commit.
export function simplifyCommitDecision(status: SimplifyStageStatus, appliedEdits: boolean): SimplifyCommitDecision {
  const commit = status === "ok" && appliedEdits;
  return { commit, rescan: commit };
}
