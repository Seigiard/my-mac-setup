// Deterministic launch validator (R6/KTD8): pure function, no I/O. Every check
// the current pipeline enforces in code is applied to a spec before launch, and
// each failure is a machine-actionable error `{invariant, blockId|edge, hint}`
// the orchestrator recomposes from. The registry (schema identities, kinds,
// external/scan flags, waive policies) and archive existence are injected so the
// validator itself touches neither the filesystem nor the block source.
import { z } from "zod/v4";

import {
  COMMAND_REF_SCHEMES,
  type FlowBlock,
  type FlowSpec,
  flowSpecSchema,
  isReservedBlockId,
  isValidBlockIdGrammar,
  type WaivePolicy,
} from "./flow-spec.ts";

type ParsedSpec = z.infer<typeof flowSpecSchema>;

export interface RegistryBlockView {
  kind: "agent" | "compute" | "subflow";
  external: boolean;
  // Non-vendor egress (branch push, PR open). Distinct from `external` because
  // no LLM payload is dispatched, but it reaches the same scan-first invariant.
  publishes: boolean;
  needsWorkspace: boolean;
  // Boundary compatibility (KTD14) keys on schema *identity*, not structural
  // subsumption: two blocks connect only when the producer's outputSchemaId
  // equals the consumer's inputSchemaId or a declared adapter reconciles them.
  inputSchemaId: string;
  outputSchemaId: string;
  waivePolicies: readonly WaivePolicy[];
  // A scan block satisfies the "secret-scan before every external leg" gate
  // (R6/AE1) for any external block reachable after it through `after` edges.
  scan: boolean;
}

export interface RegistryView {
  get(name: string): RegistryBlockView | undefined;
  hasAdapter(fromOutputSchemaId: string, toInputSchemaId: string): boolean;
}

export interface ValidatorDeps {
  registry: RegistryView;
  archiveExists: (artifactsFrom: string) => boolean;
}

export interface ValidationError {
  invariant: string;
  blockId?: string;
  edge?: [string, string];
  hint: string;
}

export type ValidateResult = { ok: true; spec: FlowSpec } | { ok: false; errors: ValidationError[] };

// Matches command-bearing field names in snake/kebab/camel forms:
// `cmd`, `setup_cmd`, `setup-cmd`, `setupCmd`, `validateCommand`, `runScript`.
const COMMAND_FIELD = /(cmd|command|script|exec|run)$/i;

// A command-bearing value is operator-sourced when it is `{ref: "..."}` or a
// string tagged `ref:`/`plan:`/`flag:`. A bare string is inline command text.
function isCommandReference(value: unknown): boolean {
  if (value && typeof value === "object" && "ref" in value && typeof (value as { ref: unknown }).ref === "string") {
    return true;
  }
  if (typeof value === "string") {
    return COMMAND_REF_SCHEMES.some((scheme) => value.startsWith(`${scheme}:`));
  }
  return false;
}

export function validateFlowSpec(raw: unknown, deps: ValidatorDeps): ValidateResult {
  const parsed = flowSpecSchema.safeParse(raw);
  if (!parsed.success) {
    return {
      ok: false,
      errors: [{ invariant: "spec-schema", hint: `spec does not match the flow-spec schema: ${parsed.error.message}` }],
    };
  }
  const spec = parsed.data;
  const errors: ValidationError[] = [];

  const ids = new Set<string>();
  for (const block of spec.blocks) {
    if (ids.has(block.id)) {
      errors.push({ invariant: "duplicate-id", blockId: block.id, hint: `two blocks share id "${block.id}"; ids must be unique` });
    }
    ids.add(block.id);
    if (!isValidBlockIdGrammar(block.id)) {
      errors.push({ invariant: "id-grammar", blockId: block.id, hint: `id "${block.id}" is not lowercase-kebab (letters, digits, single hyphens)` });
    }
    if (isReservedBlockId(block.id)) {
      errors.push({ invariant: "reserved-id", blockId: block.id, hint: `id "${block.id}" uses a reserved ladder affix (gate-/approve-/guard-/-extra/-crashed/-prep) or a fixed prolog/epilog name` });
    }
    if (block.retries === null || block.retries === undefined) {
      errors.push({ invariant: "missing-retries", blockId: block.id, hint: `block "${block.id}" must declare explicit retries (Smithers default is infinite; KTD8)` });
    }
    if (block.timeoutMs === null || block.timeoutMs === undefined) {
      errors.push({ invariant: "missing-timeout", blockId: block.id, hint: `block "${block.id}" must declare explicit timeoutMs (KTD8)` });
    }
    const entry = deps.registry.get(block.block);
    if (!entry) {
      errors.push({ invariant: "unknown-block", blockId: block.id, hint: `block "${block.id}" references catalog block "${block.block}" which is not in the registry` });
      continue;
    }
    if (!entry.waivePolicies.includes(block.waive)) {
      errors.push({ invariant: "waive-policy", blockId: block.id, hint: `waive policy "${block.waive}" is not valid for a ${entry.kind} block; allowed: ${entry.waivePolicies.join(", ")}` });
    }
    for (const [key, value] of Object.entries(block.input)) {
      if (COMMAND_FIELD.test(key) && !isCommandReference(value)) {
        errors.push({ invariant: "command-provenance", blockId: block.id, hint: `input field "${key}" inlines a command; use an operator-source reference (${COMMAND_REF_SCHEMES.map((s) => `${s}:`).join("/")} or {ref}) per KTD15` });
      }
    }
  }

  // Edge integrity: every after/bindTo target exists. Skip graph checks that
  // depend on resolvable edges when a target is missing.
  let edgesResolvable = true;
  for (const block of spec.blocks) {
    for (const dep of [...block.after, ...block.bindTo]) {
      if (!ids.has(dep)) {
        edgesResolvable = false;
        errors.push({ invariant: "unknown-edge", edge: [block.id, dep], hint: `block "${block.id}" references "${dep}" which is not a block in this spec` });
      }
    }
  }

  if (edgesResolvable) {
    const byId = new Map(spec.blocks.map((b) => [b.id, b]));
    const ancestors = afterAncestors(spec.blocks);
    const cycle = findCycle(spec.blocks);
    if (cycle) {
      errors.push({ invariant: "cycle", hint: `\`after\` edges form a cycle: ${cycle.join(" -> ")}` });
    } else {
      for (const block of spec.blocks) {
        const anc = ancestors.get(block.id) ?? new Set<string>();
        for (const target of block.bindTo) {
          if (!anc.has(target)) {
            errors.push({ invariant: "bind-unreachable", edge: [block.id, target], hint: `bindTo target "${target}" is not an \`after\`-ancestor of "${block.id}"; add the ordering edge or drop the bind` });
            continue;
          }
          const producer = byId.get(target);
          const consumer = deps.registry.get(block.block);
          const producerEntry = producer ? deps.registry.get(producer.block) : undefined;
          if (producer && consumer && producerEntry) {
            const compatible = producerEntry.outputSchemaId === consumer.inputSchemaId || deps.registry.hasAdapter(producerEntry.outputSchemaId, consumer.inputSchemaId);
            if (!compatible) {
              errors.push({ invariant: "boundary-schema", edge: [target, block.id], hint: `output of "${target}" (${producerEntry.outputSchemaId}) is not schema-compatible with input of "${block.id}" (${consumer.inputSchemaId}); declare an edge adapter or change a block` });
            }
          }
        }
      }

      // Secret-scan before every egress (R6/AE1): a block that ships run content
      // out — to an LLM vendor (`external`) or to a durable public target such as
      // a pushed branch or an opened PR (`publishes`) — must have a `scan` block
      // among its after-ancestors. Both reach the same KTD13 surface, so the
      // invariant covers both; keying it on `external` alone let the pr block
      // publish unscanned.
      for (const block of spec.blocks) {
        const entry = deps.registry.get(block.block);
        if (!entry || !(entry.external || entry.publishes)) continue;
        const egress = entry.external ? "external" : "publishing";
        const anc = ancestors.get(block.id) ?? new Set<string>();
        const scanned = [...anc].some((a) => deps.registry.get(byId.get(a)?.block ?? "")?.scan);
        if (!scanned) {
          errors.push({ invariant: "scan-before-external", blockId: block.id, hint: `${egress} block "${block.id}" has no secret-scan block among its \`after\`-ancestors; insert a scan block before it (KTD13)` });
        }
      }
    }
  }

  if (spec.artifactsFrom && !deps.archiveExists(spec.artifactsFrom)) {
    errors.push({ invariant: "artifacts-missing", hint: `artifactsFrom "${spec.artifactsFrom}" does not resolve to an existing outcome archive (KTD10)` });
  }

  if (errors.length > 0) return { ok: false, errors };
  return { ok: true, spec: normalize(spec) };
}

function normalize(spec: ParsedSpec): FlowSpec {
  const blocks: FlowBlock[] = spec.blocks.map((b) => ({
    id: b.id,
    block: b.block,
    input: b.input,
    retries: b.retries as number,
    timeoutMs: b.timeoutMs as number,
    after: b.after,
    bindTo: b.bindTo,
    waive: b.waive,
  }));
  return {
    task: { description: spec.task.description, classification: spec.task.classification ?? null },
    repo: spec.repo,
    setupCmdRef: spec.setupCmdRef ?? null,
    budgetUsd: spec.budgetUsd ?? null,
    blocks,
    artifactsFrom: spec.artifactsFrom ?? null,
  };
}

// Transitive closure of `after` edges: ancestors.get(id) is every block that
// must run before id.
function afterAncestors(blocks: Array<{ id: string; after: string[] }>): Map<string, Set<string>> {
  const direct = new Map(blocks.map((b) => [b.id, b.after]));
  const memo = new Map<string, Set<string>>();
  const visit = (id: string, stack: Set<string>): Set<string> => {
    const cached = memo.get(id);
    if (cached) return cached;
    const acc = new Set<string>();
    for (const parent of direct.get(id) ?? []) {
      if (stack.has(parent)) continue;
      acc.add(parent);
      for (const up of visit(parent, new Set(stack).add(parent))) acc.add(up);
    }
    memo.set(id, acc);
    return acc;
  };
  for (const b of blocks) visit(b.id, new Set([b.id]));
  return memo;
}

// DFS cycle detection over `after`; returns one offending path or null.
function findCycle(blocks: Array<{ id: string; after: string[] }>): string[] | null {
  const direct = new Map(blocks.map((b) => [b.id, b.after]));
  const state = new Map<string, "visiting" | "done">();
  const path: string[] = [];
  const dfs = (id: string): string[] | null => {
    state.set(id, "visiting");
    path.push(id);
    for (const next of direct.get(id) ?? []) {
      if (!direct.has(next)) continue;
      const s = state.get(next);
      if (s === "visiting") return [...path.slice(path.indexOf(next)), next];
      if (s === undefined) {
        const found = dfs(next);
        if (found) return found;
      }
    }
    path.pop();
    state.set(id, "done");
    return null;
  };
  for (const b of blocks) {
    if (state.get(b.id) === undefined) {
      const found = dfs(b.id);
      if (found) return found;
    }
  }
  return null;
}
