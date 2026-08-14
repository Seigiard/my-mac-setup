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

// KTD12: a block's bind-proof targets are the engine node ids of its declared
// dependency edges (`bindTo`), replacing hand-written fallback chains. The
// interpreter feeds these to ctx.prove so a mutated upstream row parks the run
// (BOUND_STALE) instead of dispatching against stale data.
export function bindProofTargets(block: FlowBlock): string[] {
  return block.bindTo.map(blockNodeId);
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
