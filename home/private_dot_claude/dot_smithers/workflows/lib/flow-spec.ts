// Declarative flow-spec (KTD1): the data one static interpreter (se-flow.tsx)
// executes. A spec is a DAG of typed blocks plus run-level fields. The schema is
// deliberately permissive on `retries`/`timeoutMs` (optional here) so the
// validator can name the offending block when either is missing (KTD8) instead
// of surfacing a raw Zod union error. Optionals use `.nullish()` because absent
// optionals cross Smithers subflow boundaries as `null`, not `undefined`
// (documented in docs/se-pipeline.md). Command-bearing fields never inline a
// command string — they carry an operator-source reference (KTD15); the
// validator enforces that, the schema only shapes it.
import { z } from "zod/v4";

// A red gate after retries either stops the block's successors outright (`none`)
// or parks in an approval pause the composer opted into for a risky block
// (`approval`, the R11 optional-block / R13 escalation path). The registry
// declares which policies a block kind permits; the validator checks membership
// per block.
//
// ENFORCED IN `flow-run.ts`'s `dispatchableBlocks`, which is the one pure
// function that decides which blocks may dispatch; `se-flow.tsx` renders the
// `approval` pause that decision asks for. This pointer is here because the
// contract sat in this comment with no implementation anywhere: the validator
// checked the policy against the registry and nothing ever read it at run time.
// docs/issues/2026-08-15-003 is what that cost — a red `work` block let five
// successors run, and the flow published a real pull request after a gate said
// no. A documented contract names where it is enforced, or it is decoration.
export const WAIVE_POLICIES = ["none", "approval"] as const;
export const waivePolicySchema = z.enum(WAIVE_POLICIES);
export type WaivePolicy = (typeof WAIVE_POLICIES)[number];

// A command reference: either a `{ ref }` object or a string tagged with an
// operator-source scheme. Inline command text (a bare string with no scheme) is
// rejected by the validator (KTD15).
export const COMMAND_REF_SCHEMES = ["ref", "plan", "flag"] as const;

export const flowBlockSchema = z.object({
  id: z.string(),
  block: z.string(),
  input: z.record(z.string(), z.unknown()).default({}),
  retries: z.number().int().min(0).nullish(),
  timeoutMs: z.number().int().positive().nullish(),
  after: z.array(z.string()).default([]),
  bindTo: z.array(z.string()).default([]),
  waive: waivePolicySchema.default("none"),
});
export type FlowBlockInput = z.input<typeof flowBlockSchema>;

// A normalized block is what the validator returns on success: retries and
// timeoutMs are guaranteed present (the validator rejected any block missing
// them), so downstream interpreter code reads them without re-checking.
export interface FlowBlock {
  id: string;
  block: string;
  input: Record<string, unknown>;
  retries: number;
  timeoutMs: number;
  after: string[];
  bindTo: string[];
  waive: WaivePolicy;
}

export const flowTaskSchema = z.object({
  description: z.string().min(1),
  classification: z.string().nullish(),
});

export const flowSpecSchema = z.object({
  task: flowTaskSchema,
  repo: z.string().min(1),
  setupCmdRef: z.union([z.string(), z.object({ ref: z.string() })]).nullish(),
  budgetUsd: z.number().positive().nullish(),
  blocks: z.array(flowBlockSchema).min(1),
  artifactsFrom: z.string().nullish(),
});
export type FlowSpecInput = z.input<typeof flowSpecSchema>;

export interface FlowSpec {
  task: { description: string; classification: string | null };
  repo: string;
  setupCmdRef: string | { ref: string } | null;
  budgetUsd: number | null;
  blocks: FlowBlock[];
  artifactsFrom: string | null;
}

// Reserved id affixes: the interpreter derives engine node ids from spec block
// ids and its own fixed ladder uses these shapes (`gate-<x>`, `approve-<x>-1`,
// `guard-<x>`, `<x>-extra`, `<x>-crashed`, `<x>-extra-prep`) plus fixed
// prolog/epilog node ids. A spec id colliding with any of them would let two
// engine nodes share an id and corrupt resume, so the validator refuses them
// even though the interpreter also namespaces spec ids under `b:` (KTD1).
export const RESERVED_ID_PREFIXES = ["gate-", "gate0", "approve-", "guard-", "b:"] as const;
export const RESERVED_ID_SUFFIXES = ["-extra", "-crashed", "-prep"] as const;
export const RESERVED_ID_EXACT = new Set([
  "gate0",
  "staging",
  "setup",
  "cleanup",
  "outcome",
  "reviewer",
  "budget",
  "summary",
]);

// Lowercase kebab: starts with a letter, segments joined by single hyphens.
const ID_GRAMMAR = /^[a-z][a-z0-9]*(-[a-z0-9]+)*$/;

export function isReservedBlockId(id: string): boolean {
  if (RESERVED_ID_EXACT.has(id)) return true;
  if (RESERVED_ID_PREFIXES.some((p) => id.startsWith(p))) return true;
  if (RESERVED_ID_SUFFIXES.some((s) => id.endsWith(s))) return true;
  return false;
}

export function isValidBlockIdGrammar(id: string): boolean {
  return ID_GRAMMAR.test(id);
}
