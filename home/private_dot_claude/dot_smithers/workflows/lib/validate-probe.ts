// Preflight for the work gate's validate-cmd: a staged run worktree is a bare
// checkout — tracked files only, no node_modules, no built dists — so a runner
// resolved from a package manager's bin directory is simply absent and the
// command exits 127. Learning that at the work gate costs a full agent leg;
// resolving the command's head words in the staged worktree costs seconds.
// Pure classification (KTD3): resolution itself is injected by the caller so
// the probe runs through the SAME shell wrapper as the real validate-cmd.

// Head words that cannot be read statically — a variable, a command
// substitution, a glob, a quoted span. Probing one reports a phantom miss, so
// the probe skips it: it refuses only what it is sure about.
const DYNAMIC = /[$`*?"'\\{}]/;
const HEAD_WORD = /^[A-Za-z0-9_./][A-Za-z0-9_./-]*$/;
const ENV_ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=\S*\s+/;
// A command that installs or builds before it verifies creates its own runner,
// so a head absent at probe time may exist by the time it runs. The probe stays
// silent rather than refusing a launch that would have worked.
const PROVISION_STEP = /\b(install|ci|sync|bootstrap|setup|build|compile|restore)\b/;

export interface ProbeReport {
  probed: string[];
  missing: string[];
  // True when the command provisions itself, so no head was judged at all.
  skipped: boolean;
}

export function probeValidateCmd(cmd: string, resolves: (head: string) => boolean): ProbeReport {
  if (selfProvisioning(cmd)) return { probed: [], missing: [], skipped: true };
  const probed = commandHeads(cmd);
  return { probed, missing: probed.filter((head) => !resolves(head)), skipped: false };
}

export function missingRunnerMessage(cmd: string, missing: string[]): string {
  const names = missing.map((m) => `"${m}"`).join(", ");
  return [
    `validate-cmd cannot run in the staged run worktree: ${names} not found on PATH (this is what exit 127 would report at the work gate).`,
    "A fresh git worktree holds tracked files only — no node_modules, no built dists — so a runner installed by the package manager is absent.",
    "Provision the worktree with --setup-cmd (e.g. --setup-cmd 'bun install'), or name a runner the package manager resolves (e.g. --validate-cmd 'bun run test').",
    `validate-cmd: ${cmd}`,
  ].join(" ");
}

export function commandHeads(cmd: string): string[] {
  const heads: string[] = [];
  const seen = new Set<string>();
  for (const segment of splitSegments(cmd)) {
    const head = segmentHead(segment);
    if (head === null || seen.has(head)) continue;
    seen.add(head);
    heads.push(head);
  }
  return heads;
}

export function selfProvisioning(cmd: string): boolean {
  return splitSegments(cmd).some((segment) => PROVISION_STEP.test(segment.toLowerCase()) || /^make(\s|$)/.test(segment));
}

// Quote-aware split on the operators that start a new command. `(` and `)`
// split too: the derivation in lib/plan.ts joins commands as `(a) && (b)`.
export function splitSegments(cmd: string): string[] {
  const segments: string[] = [];
  let current = "";
  let quote: string | null = null;
  for (let i = 0; i < cmd.length; i++) {
    const ch = cmd[i];
    if (quote !== null) {
      current += ch;
      if (ch === quote && cmd[i - 1] !== "\\") quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      current += ch;
      continue;
    }
    if (ch === "&" || ch === "|") {
      if (cmd[i + 1] === ch) i++;
      segments.push(current);
      current = "";
      continue;
    }
    if (ch === ";" || ch === "\n" || ch === "(" || ch === ")") {
      segments.push(current);
      current = "";
      continue;
    }
    current += ch;
  }
  segments.push(current);
  return segments.map((s) => s.trim()).filter((s) => s !== "");
}

export function segmentHead(segment: string): string | null {
  let rest = segment.trim();
  let assignment: RegExpExecArray | null;
  while ((assignment = ENV_ASSIGNMENT.exec(rest)) !== null) rest = rest.slice(assignment[0].length);
  const head = rest.split(/\s+/)[0] ?? "";
  if (head === "" || DYNAMIC.test(head) || !HEAD_WORD.test(head)) return null;
  return head;
}

export function shellQuote(word: string): string {
  return `'${word.replaceAll("'", `'\\''`)}'`;
}

// Why a validate-cmd failed, which decides who has to act. "assertion" is the
// code's problem and belongs to the work agent. The other three are the
// worktree's problem and no amount of agent work fixes them — on
// run-1786718288581 the same environment failure was paid for twice, because
// exit 1 with a broken module resolution is indistinguishable from a failing
// test if you only read the exit code.
export type ValidateFailureKind = "missing-runner" | "missing-module" | "timeout" | "assertion";

const COMMAND_NOT_FOUND = /([^\s:]+):\s*command not found/i;
// The vocabulary every runtime uses for "the file this import names is not on
// disk": node/bun, python, and the bundlers. Deliberately not exhaustive — an
// unmatched message falls through to "assertion", which is the safe direction,
// because it lets the run proceed rather than refusing a healthy launch.
const MISSING_MODULE =
  /(cannot find module|module not found|module_not_found|modulenotfounderror|no module named|cannot find package|failed to resolve import|cannot resolve entry)/i;
const TERMINATED = "terminated (timeout or signal)";

export function classifyValidateFailure(exitCode: number, output: string): ValidateFailureKind {
  if (exitCode === 127) return output.includes(TERMINATED) ? "timeout" : "missing-runner";
  if (MISSING_MODULE.test(output)) return "missing-module";
  return "assertion";
}

// The module path from the first "Cannot find module '<path>'" the runtime
// printed, so the refusal can name what is absent instead of the whole tail.
export function missingModuleName(output: string): string | null {
  const quoted = /(?:cannot find module|cannot find package|no module named)\s+['"`]([^'"`]+)['"`]/i.exec(output);
  return quoted ? quoted[1] : null;
}

export function environmentFailureMessage(cmd: string, kind: ValidateFailureKind, output: string): string {
  const named = missingModuleName(output);
  const what =
    kind === "missing-runner"
      ? `the runner ${COMMAND_NOT_FOUND.exec(output)?.[1] ?? "(unnamed)"} is not installed`
      : `${named === null ? "a module" : `the module "${named}"`} cannot be resolved`;
  return [
    `validate-cmd fails in the staged run worktree before any work has been done: ${what}.`,
    "A fresh git worktree holds tracked files only — no node_modules, no built workspace dists — so this is the worktree's state, not a failing test, and no amount of agent work will fix it.",
    "Provision the worktree with --setup-cmd (e.g. --setup-cmd 'bun install && bunx turbo run build --filter=<pkg>'), or scope --validate-cmd to what a bare checkout can run.",
    `validate-cmd: ${cmd}`,
  ].join(" ");
}
