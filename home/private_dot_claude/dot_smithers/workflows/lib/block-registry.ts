// Block contract and registry (R1/KTD3/KTD6/KTD14). A block is a typed unit the
// interpreter dispatches and the validator reasons about. The registry is the
// single home for block definitions; `se blocks --json` renders its catalog and
// the orchestrator composes from that catalog, never from this source. Boundary
// compatibility keys on schema *identity* (a declared id shared between a
// producer's output and a consumer's input), not structural JSON-Schema
// subsumption — JSON Schema cannot carry `.refine()`/`.transform()`/`.nullish()`
// semantics, so the interpreter runtime-parses every block input with the
// registered zod schema at dispatch (KTD14); the catalog documents this limit.
import { z } from "zod/v4";

import type { GateResult } from "./gates.ts";
import type { WaivePolicy } from "./flow-spec.ts";
import type { RegistryBlockView, RegistryView } from "./flow-validate.ts";

export type BlockKind = "agent" | "compute" | "subflow";

// Which waive policies each kind may declare. A compute block is a pure effect
// step (commit, scan, artifact collection); a red gate there is a hard stop, so
// it never offers the approval-waive path. Agent and subflow blocks may.
export const KIND_WAIVE_POLICIES: Record<BlockKind, readonly WaivePolicy[]> = {
  compute: ["none"],
  agent: ["none", "approval"],
  subflow: ["none", "approval"],
};

export interface CostProfile {
  estUsd: number;
}

// External blocks (`external: true`) egress data to a third-party vendor. The
// contract forces the KTD13 dispatch-time payload scan and the read-only
// ask-agent invocation path; a block that omits it is refused at registration.
export interface ExternalContract {
  dispatchScan: true;
  invocation: "read-only-ask-agent";
}

export interface AgentBuild {
  worktreePath: string;
  timeoutMs: number;
  budgetUsd: number;
}

interface BlockDefinitionBase {
  name: string;
  kind: BlockKind;
  purpose: string;
  inputSchema: z.ZodType;
  outputSchema: z.ZodType;
  // Schema identity for boundary compatibility (KTD14). Two blocks connect when
  // a producer's outputSchemaId equals a consumer's inputSchemaId (or a declared
  // adapter reconciles them). Share one id across blocks that speak one shape.
  inputSchemaId: string;
  outputSchemaId: string;
  external: boolean;
  // Egress that is not vendor egress: a block that pushes a branch, opens a PR,
  // or otherwise writes run content somewhere durable and outside the worktree.
  // It carries no ExternalContract because nothing is dispatched to an LLM, but
  // it must still be scanned before it runs — KTD13's publication-time surface.
  // Defaults to false; the validator treats `external || publishes` alike.
  publishes?: boolean;
  needsWorkspace: boolean;
  scan: boolean;
  preconditions: string[];
  waivePolicies: readonly WaivePolicy[];
  defaults: { retries: number; timeoutMs: number };
  costProfile: CostProfile;
  // Pure classification of the block's recorded output (KTD4): no I/O.
  gateFn: (recorded: unknown) => GateResult;
  externalContract?: ExternalContract;
}

export interface AgentBlockDefinition extends BlockDefinitionBase {
  kind: "agent";
  // The interpreter dispatches an agent block exclusively through these two
  // members (KTD3): makeAgent builds the smithers agent, buildPrompt renders the
  // instruction from the runtime-parsed input.
  makeAgent: (build: AgentBuild) => unknown;
  buildPrompt: (input: unknown) => string;
}

export interface ComputeBlockDefinition extends BlockDefinitionBase {
  kind: "compute";
}

export interface SubflowBlockDefinition extends BlockDefinitionBase {
  kind: "subflow";
  // KTD3 closed mirror-key set: a subflow block writes its own output shape into
  // this fixed key; the interpreter copies that row into the generic blockOutput.
  mirrorKey: string;
}

export type BlockDefinition = AgentBlockDefinition | ComputeBlockDefinition | SubflowBlockDefinition;

export interface CatalogEntry {
  name: string;
  kind: BlockKind;
  purpose: string;
  inputSchema: unknown;
  outputSchema: unknown;
  inputSchemaId: string;
  outputSchemaId: string;
  external: boolean;
  publishes: boolean;
  needsWorkspace: boolean;
  scan: boolean;
  preconditions: string[];
  waivePolicies: WaivePolicy[];
  defaults: { retries: number; timeoutMs: number };
  costProfile: CostProfile;
}

export const CATALOG_SCHEMA_NOTE =
  "JSON Schema below omits zod .refine()/.transform()/.nullish() constraints; the interpreter runtime-parses every input with the registered zod schema at dispatch (KTD14), which is the authority.";

function adapterKey(fromOutputSchemaId: string, toInputSchemaId: string): string {
  return `${fromOutputSchemaId}|${toInputSchemaId}`;
}

export class BlockRegistry {
  private readonly blocks = new Map<string, BlockDefinition>();
  private readonly adapters = new Set<string>();

  register(def: BlockDefinition): void {
    if (this.blocks.has(def.name)) {
      throw new Error(`block "${def.name}" is already registered`);
    }
    const allowed = KIND_WAIVE_POLICIES[def.kind];
    for (const policy of def.waivePolicies) {
      if (!allowed.includes(policy)) {
        throw new Error(`block "${def.name}" (${def.kind}) declares waive policy "${policy}"; a ${def.kind} block allows only: ${allowed.join(", ")}`);
      }
    }
    if (def.external && !def.externalContract) {
      throw new Error(`external block "${def.name}" must declare a data-sharing contract (dispatch-time scan + read-only invocation, KTD13)`);
    }
    this.blocks.set(def.name, def);
  }

  // A declared edge adapter reconciles a named producer→consumer schema pair the
  // validator would otherwise refuse.
  declareAdapter(fromOutputSchemaId: string, toInputSchemaId: string): void {
    this.adapters.add(adapterKey(fromOutputSchemaId, toInputSchemaId));
  }

  get(name: string): BlockDefinition | undefined {
    return this.blocks.get(name);
  }

  list(): BlockDefinition[] {
    return [...this.blocks.values()].sort((a, b) => a.name.localeCompare(b.name));
  }

  // The read-only projection the deterministic validator consumes.
  view(): RegistryView {
    return {
      get: (name): RegistryBlockView | undefined => {
        const def = this.blocks.get(name);
        if (!def) return undefined;
        return {
          kind: def.kind,
          external: def.external,
          publishes: def.publishes === true,
          needsWorkspace: def.needsWorkspace,
          inputSchemaId: def.inputSchemaId,
          outputSchemaId: def.outputSchemaId,
          waivePolicies: def.waivePolicies,
          scan: def.scan,
        };
      },
      hasAdapter: (from, to) => this.adapters.has(adapterKey(from, to)),
    };
  }

  // Exact-schema compatibility check exposed for the orchestrator's own
  // dry-composition checks (mirrors the validator's boundary rule).
  compatible(fromOutputSchemaId: string, toInputSchemaId: string): boolean {
    return fromOutputSchemaId === toInputSchemaId || this.adapters.has(adapterKey(fromOutputSchemaId, toInputSchemaId));
  }

  catalog(): CatalogEntry[] {
    return this.list().map((def) => ({
      name: def.name,
      kind: def.kind,
      purpose: def.purpose,
      inputSchema: z.toJSONSchema(def.inputSchema),
      outputSchema: z.toJSONSchema(def.outputSchema),
      inputSchemaId: def.inputSchemaId,
      outputSchemaId: def.outputSchemaId,
      external: def.external,
      publishes: def.publishes === true,
      needsWorkspace: def.needsWorkspace,
      scan: def.scan,
      preconditions: def.preconditions,
      waivePolicies: [...def.waivePolicies],
      defaults: def.defaults,
      costProfile: def.costProfile,
    }));
  }
}

// Stable, byte-identical serialization for diffing and round-trip: keys sorted
// recursively so two consecutive generations of the same registry match exactly.
export function catalogToJson(registry: BlockRegistry): string {
  return JSON.stringify({ note: CATALOG_SCHEMA_NOTE, blocks: registry.catalog() }, sortedReplacer(), 2);
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
