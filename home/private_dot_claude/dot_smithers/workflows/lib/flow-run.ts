// Pure interpreter helpers for se-flow.tsx (KTD1/KTD2/KTD3/KTD12). Kept out of
// the workflow file so they are unit-testable without a Smithers runtime and so
// the workflow's statically-imported module graph stays stable across runs (a
// change here is still governed by KTD1's zero-in-flight rule). Every function
// here is deterministic: the same spec yields the same node ids, the same
// workspace decision, and the same block order — the resume-stability property
// the whole architecture depends on.
import { createHash } from "node:crypto";

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
// Withholding STOPS the list rather than skipping the block: bindTo targets are
// `after`-ancestors (flow-validate's bind-unreachable invariant) and `ordered`
// is a topological order, so no block past an unready one may legally run.
export function dispatchableBlocks(
  ordered: FlowBlock[],
  rowNodeId: (blockId: string) => string | undefined,
): DispatchableBlock[] {
  const dispatchable: DispatchableBlock[] = [];
  for (const block of ordered) {
    const bindNodeIds: string[] = [];
    for (const target of block.bindTo) {
      const nodeId = rowNodeId(target);
      if (nodeId === undefined) return dispatchable;
      bindNodeIds.push(nodeId);
    }
    dispatchable.push({ block, bindNodeIds });
  }
  return dispatchable;
}

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
