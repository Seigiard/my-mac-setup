// Pure interpreter helpers for se-flow.tsx (KTD1/KTD2/KTD3/KTD12). Kept out of
// the workflow file so they are unit-testable without a Smithers runtime and so
// the workflow's statically-imported module graph stays stable across runs (a
// change here is still governed by KTD1's zero-in-flight rule). Every function
// here is deterministic: the same spec yields the same node ids, the same
// workspace decision, and the same block order — the resume-stability property
// the whole architecture depends on.
import { createHash } from "node:crypto";
import * as path from "node:path";

import type { FlowBlock, FlowSpec } from "./flow-spec.ts";

// Spec block ids are namespaced under `b:` so a spec-chosen name can never
// collide with the interpreter's fixed ladder ids (gate-*, approve-*, guard-*,
// -extra, -crashed) or prolog/epilog ids (KTD1). The validator already refused
// reserved affixes; this prefix is the structural backstop.
export const BLOCK_NODE_PREFIX = "b:";

export function blockNodeId(blockId: string): string {
  return `${BLOCK_NODE_PREFIX}${blockId}`;
}

export interface FlowPlanEntry {
  estUsd: number;
  kind: string;
}

// R10: the operator sees what a launch will run and what it may cost, before
// it starts. Two totals, because one number would mislead: the baseline is one
// attempt per block, the ceiling assumes every block exhausts its retries. A
// block the registry does not know contributes no cost and is marked, rather
// than being dropped from the list — an unknown block is exactly what the
// reader needs to notice.
export function formatFlowPlan(
  description: string,
  blocks: FlowBlock[],
  lookup: (blockName: string) => FlowPlanEntry | undefined,
): string {
  const ordered = topoOrder(blocks);
  const idWidth = Math.max(2, ...ordered.map((b) => b.id.length));
  const nameWidth = Math.max(5, ...ordered.map((b) => b.block.length));

  let baseline = 0;
  let ceiling = 0;
  const rows = ordered.map((block, index) => {
    const entry = lookup(block.block);
    const est = entry?.estUsd ?? 0;
    baseline += est;
    ceiling += est * (1 + block.retries);
    const kind = entry?.kind ?? "UNKNOWN BLOCK";
    const cost = entry ? `~$${est}` : "—";
    return `  ${String(index + 1).padStart(2)}. ${block.id.padEnd(idWidth)}  ${block.block.padEnd(nameWidth)}  ${kind.padEnd(13)}  ${cost}`;
  });

  const retryNote = ceiling > baseline ? `, up to ~$${round2(ceiling)} if every block exhausts its retries` : "";
  return [
    `flow: ${description}`,
    `${ordered.length} block${ordered.length === 1 ? "" : "s"}, estimated ~$${round2(baseline)}${retryNote}`,
    ...rows,
  ].join("\n");
}

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}

// Agent and subflow blocks occupy two engine nodes: the dispatch node that
// produces the raw envelope, and the block node that classifies it into
// blockOutput. The dispatch node keeps the block node's id as its stem so both
// stay derived from spec content and resume matches (KTD1). Spec ids cannot
// contain ":", so neither suffix can collide with a block id.
export function dispatchNodeId(blockNodeIdValue: string): string {
  return `${blockNodeIdValue}:dispatch`;
}

// KTD2: the lock + worktree staging + setup prolog runs only when at least one
// block needs a workspace. A flow of workspace-free blocks (research,
// doc-review) acquires no lock and stages no worktree. The decision is computed
// from catalog flags, never spec-expressible.
export function needsWorkspace(spec: FlowSpec, blockNeedsWorkspace: (blockName: string) => boolean): boolean {
  return spec.blocks.some((b) => blockNeedsWorkspace(b.block));
}

export interface PlanBearingBlock {
  blockId: string;
  planPath: string;
}

// The plan path an agent block's input carries, if any. An empty string is no
// path: the prompt would name nothing and the staging step would freeze nothing.
export function blockPlanPath(input: unknown): string | undefined {
  const value = (input as { planPath?: unknown } | null | undefined)?.planPath;
  return typeof value === "string" && value.trim() !== "" ? value : undefined;
}

// Which blocks need a frozen plan copy staged for them (docs/issues/2026-08-15-002).
// AGENT blocks only: an agent is dispatched with the worktree as its cwd and
// resolves paths itself, which is the escape route a launcher path opens
// (run-1786717826270). A subflow block carrying a planPath (doc-review) hands
// the document to a workflow that copies it into its own harness, and no coding
// agent ever runs against it.
//
// Throws on two blocks whose plans share a basename: stageRunPlan keys the copy
// on the basename alone, so the second copy would overwrite the first and one
// block would silently execute the other's plan. Refusing to launch is the only
// honest answer — the same posture topoOrder takes on a cyclic spec.
export function planBearingAgentBlocks(
  ordered: FlowBlock[],
  isAgentBlock: (blockName: string) => boolean,
): PlanBearingBlock[] {
  const found: PlanBearingBlock[] = [];
  const byBasename = new Map<string, string>();
  for (const block of ordered) {
    if (!isAgentBlock(block.block)) continue;
    const planPath = blockPlanPath(block.input);
    if (planPath === undefined) continue;
    const basename = path.basename(planPath);
    const owner = byBasename.get(basename);
    if (owner !== undefined && owner !== planPath) {
      throw new Error(
        `blocks name two different plans with the same file name "${basename}" (${owner} and ${planPath}) — the frozen run copies would collide`,
      );
    }
    byBasename.set(basename, planPath);
    found.push({ blockId: block.id, planPath });
  }
  return found;
}

// Substitutes the frozen copy's path into a block input on the way to
// buildPrompt. The block's own prompt builder stays pure over its input, which
// is why the interpreter — the only layer that knows both the staged copy and
// the launcher's path — is where the swap happens.
export function withStagedPlanPath(input: unknown, copyPath: string): unknown {
  if (blockPlanPath(input) === undefined) return input;
  return { ...(input as Record<string, unknown>), planPath: copyPath };
}

// Appended by the interpreter rather than written into buildPrompt: only the
// interpreter knows whether the path in the prompt is a copy it froze or the
// operator's own file (a workspace-free flow stages nothing, and a run resumed
// from a row persisted before the copy existed has none), and a prompt must not
// claim a provenance that is not true.
export function frozenPlanNote(copyPath: string): string {
  return `

The plan file at ${copyPath} is a FROZEN COPY, staged for this run only. It lives OUTSIDE every repository on purpose: it is not a file of the target repository and it is not the operator's plan file. Never look for the repository that contains it — EVERY repository path you resolve, read, or write belongs to your cwd.`;
}

// Deterministic topological order over `after` edges. Ties break by block id so
// two runs of the same spec order blocks identically (resume stability). Assumes
// a validated acyclic spec; throws on a residual cycle rather than looping.
export function topoOrder(blocks: FlowBlock[]): FlowBlock[] {
  const byId = new Map(blocks.map((b) => [b.id, b]));
  const indegree = new Map(blocks.map((b) => [b.id, 0]));
  const dependents = new Map<string, string[]>();
  for (const b of blocks) {
    for (const dep of b.after) {
      if (!byId.has(dep)) continue;
      indegree.set(b.id, (indegree.get(b.id) ?? 0) + 1);
      (dependents.get(dep) ?? dependents.set(dep, []).get(dep)!).push(b.id);
    }
  }
  const ready = [...indegree.entries()].filter(([, d]) => d === 0).map(([id]) => id).sort();
  const order: FlowBlock[] = [];
  while (ready.length > 0) {
    const id = ready.shift()!;
    order.push(byId.get(id)!);
    for (const next of (dependents.get(id) ?? []).sort()) {
      const d = (indegree.get(next) ?? 0) - 1;
      indegree.set(next, d);
      if (d === 0) {
        ready.push(next);
        ready.sort();
      }
    }
  }
  if (order.length !== blocks.length) {
    throw new Error("topoOrder received a cyclic spec — validate before interpreting");
  }
  return order;
}

export interface DispatchableBlock {
  block: FlowBlock;
  bindNodeIds: string[];
}

// A block's settled verdict, as the durable rows express it: the engine node the
// row landed on (the block node, or the guard's `-crashed` node when the block
// threw its retries away) plus that row's `status`.
//
// Presence of this row IS the "retries are spent" proof, which is why nothing
// here carries an attempt counter. A Smithers Task persists an output row only
// on the attempt that RETURNS; a thrown attempt emits NodeFailed and re-runs,
// writing nothing. And a red gate is a returned value, never a throw — the
// classify/effect task returns `status: "failed"` and completes — so a red
// status can never be a transient attempt that a later retry replaced. When
// every attempt throws, the guard's catch writes the `-crashed` row instead,
// which is equally terminal and equally red.
export interface RecordedBlock {
  nodeId: string;
  status: string;
}

// What the operator did with a `waive: "approval"` pause. `pending` is the safe
// default: an undecided pause withholds, so a reader that cannot see the
// approval row never lets a red block through.
export type GateApprovalDecision = "approved" | "denied" | "pending";

// Why a red block is holding its successors back.
export type RedStopReason = "stopped" | "parked" | "denied";

export interface RedStop {
  blockId: string;
  block: string;
  status: string;
  reason: RedStopReason;
}

export interface FlowDispatch {
  dispatchable: DispatchableBlock[];
  // Block ids whose red gate must render an `Approval` node (waive: "approval"),
  // whether or not it has been decided yet — the node stays in the graph so the
  // decision has somewhere durable to live.
  gateApprovals: string[];
  // Block ids withheld because an ancestor gated red, in topological order.
  withheld: string[];
  // Withheld block id → the RED block the withholding traces back to. Kept
  // because the waive-approval prompt must list what THIS gate is holding, not
  // everything every red block in the flow is holding — an operator deciding one
  // gate should not be shown another gate's consequences.
  withheldBy: Record<string, string>;
  // The red blocks doing the withholding, in topological order.
  stops: RedStop[];
}

// The blocks a single red gate is holding back, in topological order.
export function withheldByBlock(dispatch: FlowDispatch, blockId: string): string[] {
  return dispatch.withheld.filter((id) => dispatch.withheldBy[id] === blockId);
}

// Anything that is not green is red. Same rule the terminal reviewer applies to
// the outcome record (reviewer.ts FAILURE_STATUSES): `failed`, `degraded`,
// `stopped` and `non-terminal` are all "the block did not pass", and a run must
// never treat a leg that vanished as a leg that succeeded.
export function isRedStatus(status: string): boolean {
  return status !== "green";
}

// KTD12: a block binds to the engine node ids of its `bindTo` edges, so a
// mutated upstream row parks the run (BOUND_STALE) instead of dispatching
// against stale data. Which blocks may be rendered at all is decided here.
//
// A target with no durable row yet cannot be proved, and ctx.prove returns
// undefined for it. Handing that undefined to a Task's `bind` does not make the
// engine wait — it parks the node as waiting-bound and the run as
// waiting-event, with an empty error and no path forward. So an unready block
// is withheld from the render until its authority rows exist.
//
// Withholding on an unready bind STOPS the list rather than skipping the block:
// bindTo targets are `after`-ancestors (flow-validate's bind-unreachable
// invariant) and `ordered` is a topological order, so no block past an unready
// one may legally run.
//
// A RED block withholds differently — only what depends on it, transitively,
// through `after` and `bindTo` alike. This is the WAIVE_POLICIES contract
// (flow-spec.ts) finally executing: under `none` a red gate stops its
// successors, under `approval` it parks until the operator decides. Enforcing it
// here rather than in the interpreter puts the policy in the one pure function
// that already answers "may this block run", so it is testable without an
// engine. It sat unenforced through docs/issues/2026-08-15-003: block `work`
// gated red and `commit-work`, `run-validate`, `proof-artifacts`, `secret-scan`
// and `pr` all ran after it, publishing a real pull request on a real remote
// after a gate had said no. Row PRESENCE was the only thing this function ever
// read; a red block writes a row too.
//
// Independent branches are deliberately untouched: a red block stops what
// depends on it, not the whole DAG. Only the epilog is unconditional.
export function dispatchableBlocks(
  ordered: FlowBlock[],
  recorded: (blockId: string) => RecordedBlock | undefined,
  gateApproval: (blockId: string) => GateApprovalDecision = () => "pending",
): FlowDispatch {
  const dispatchable: DispatchableBlock[] = [];
  const gateApprovals: string[] = [];
  const withheld: string[] = [];
  const withheldBy: Record<string, string> = {};
  const stops: RedStop[] = [];
  // Blocks whose dependents may not run. Seeded by red blocks and grown by their
  // withheld dependents, which is what makes the withholding transitive: a
  // topological order guarantees every dependency is visited before its
  // dependent, so one forward pass closes the set.
  const withholding = new Set<string>();

  for (const block of ordered) {
    const blockedBy = [...block.after, ...block.bindTo].find((dep) => withholding.has(dep));
    if (blockedBy !== undefined) {
      withholding.add(block.id);
      withheld.push(block.id);
      // A withheld blocker traces back to the red block that withheld IT, so the
      // root is the same all the way down a chain.
      withheldBy[block.id] = withheldBy[blockedBy] ?? blockedBy;
      continue;
    }

    const bindNodeIds: string[] = [];
    let bindsReady = true;
    for (const target of block.bindTo) {
      const row = recorded(target);
      if (row === undefined) {
        bindsReady = false;
        break;
      }
      bindNodeIds.push(row.nodeId);
    }
    if (!bindsReady) break;
    dispatchable.push({ block, bindNodeIds });

    const row = recorded(block.id);
    if (row === undefined || !isRedStatus(row.status)) continue;

    if (block.waive !== "approval") {
      withholding.add(block.id);
      stops.push({ blockId: block.id, block: block.block, status: row.status, reason: "stopped" });
      continue;
    }

    gateApprovals.push(block.id);
    const decision = gateApproval(block.id);
    if (decision === "approved") continue;
    withholding.add(block.id);
    stops.push({ blockId: block.id, block: block.block, status: row.status, reason: decision === "denied" ? "denied" : "parked" });
  }

  return { dispatchable, gateApprovals, withheld, withheldBy, stops };
}

// The fixed epilog writes the outcome record and the artifact archive, so it has
// to render on every exit path — including one cut short by a red gate.
// docs/issues/2026-08-14-004 is the incident that made this a rule: work that
// must happen even when a leg dies belongs OUTSIDE that leg's failure path.
//
// Withholding cannot starve it. A withheld block leaves `allRecorded` false, but
// withholding only ever happens because some block recorded a red row, which is
// exactly what `anyRed` sees — so a stopped run always satisfies the second arm.
export function epilogShouldRender(ordered: FlowBlock[], recorded: (blockId: string) => RecordedBlock | undefined): boolean {
  const rows = ordered.map((b) => recorded(b.id));
  return rows.every((row) => row !== undefined) || rows.some((row) => row !== undefined && isRedStatus(row.status));
}

export interface FlowVerdict {
  state: "completed" | "stopped-by-red-gate" | "parked-for-waive-approval";
  // The block that stopped the run, `<id> (<kind>): <status>`, or null when
  // nothing did.
  stoppedBy: string | null;
  summary: string;
  // Every block the run withheld, not only the ones `stoppedBy` withheld — two
  // red blocks on independent branches both contribute here.
  withheld: string[];
}

// R11/KTD10: a run cut short by a red gate must not report the same terminal
// state as a clean one. The outcome record and the `outcome` row carry this, so
// an operator reads what happened instead of inferring it from a table of block
// statuses — the failure mode of issue 2026-08-15-003, where the run reported
// `finished` with a red row buried in the middle of it.
export function flowVerdict(dispatch: FlowDispatch): FlowVerdict {
  const { stops, withheld } = dispatch;
  if (stops.length === 0) {
    return { state: "completed", stoppedBy: null, summary: "no block gated red; nothing was withheld", withheld: [] };
  }
  // A hard stop outranks a park when both are present: a parked run can still be
  // released by an operator, a stopped one cannot, and the verdict must lead
  // with the outcome that is not recoverable.
  const primary = stops.find((s) => s.reason !== "parked") ?? stops[0]!;
  // Phrased as a run-level fact rather than attributed to `primary`: with two
  // red blocks on independent branches, not every withheld block is that one's.
  const tail = withheld.length === 0
    ? "nothing downstream was left to withhold"
    : `${withheld.length} downstream block${withheld.length === 1 ? "" : "s"} never ran: ${withheld.join(", ")}`;
  return {
    state: primary.reason === "parked" ? "parked-for-waive-approval" : "stopped-by-red-gate",
    stoppedBy: `${primary.blockId} (${primary.block}): ${primary.status}`,
    summary: `run ${REASON_VERB[primary.reason]} at block "${primary.blockId}" (${primary.block}), which gated red (${primary.status}); ${tail}`,
    withheld: [...withheld],
  };
}

const REASON_VERB: Record<RedStopReason, string> = {
  stopped: "stopped",
  parked: "parked for a waive approval",
  denied: "stopped by a denied waive approval",
};

// Canonical spec serialization: keys sorted recursively so the hash is
// invariant to key order in the source JSON. The hash is the gate0-role spec
// provenance row (KTD2) and the anchor the expensive blocks bind to.
export function canonicalSpecJson(spec: FlowSpec): string {
  return JSON.stringify(spec, sortedReplacer());
}

export function specHash(spec: FlowSpec): string {
  return createHash("sha256").update(canonicalSpecJson(spec)).digest("hex");
}

function sortedReplacer(): (key: string, value: unknown) => unknown {
  return (_key, value) => {
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const record = value as Record<string, unknown>;
      return Object.fromEntries(Object.keys(record).sort().map((k) => [k, record[k]]));
    }
    return value;
  };
}

export interface PrBodyBlockStatus {
  blockId: string;
  block: string;
  status: string;
}

// R11: the PR body embeds the spec and the run's recorded status, so a reviewer
// who opens the PR sees what was asked for and what happened without going to
// the Smithers state directory.
//
// The status list is a snapshot taken when the `pr` block runs, not the final
// outcome record — the record is written in the epilog, which by definition has
// not happened yet while a block is still executing. Saying "so far" in the body
// is the honest framing; claiming to embed a final record would not be.
export function formatPrBody(runId: string, specJson: string, blocks: PrBodyBlockStatus[]): string {
  const rows = blocks.length > 0
    ? blocks.map((b) => `| \`${b.blockId}\` | ${b.block} | ${b.status} |`).join("\n")
    : "| — | — | no block had recorded a status when the PR was opened |";
  return `Opened by se-flow run \`${runId}\`.

## Block status so far

| Block | Kind | Status |
|---|---|---|
${rows}

The run's terminal outcome record and artifact archive are written by the epilog, after this PR opens; they live under the Smithers state directory keyed by this run id.

## Flow spec

\`\`\`json
${specJson}
\`\`\`
`;
}
