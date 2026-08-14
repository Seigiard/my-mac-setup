// Salvage (U5/KTD10): synthesize an outcome record for a run that was killed
// before its epilog. Without this, a run terminated mid-flight leaves nothing an
// `artifactsFrom` handoff can point at, and the work it did do is unreachable
// even though every block row is sitting in smithers.db.
//
// A killed run is the one case where the staged worktree SURVIVES — cleanup
// never ran — so salvage can still copy the manifest artifacts out of it. That
// is the difference between a salvaged archive and an empty directory.
import { copyArtifacts, planArtifactArchive, type ArchiveResult, type BlockPayload } from "./archive.ts";
import type { BlockOutcome, BlockStatus, OutcomeRecord } from "./reviewer.ts";

export interface SalvagedBlockRow {
  blockId: string;
  status: string;
  payloadJson: string;
}

export interface SalvageInput {
  runId: string;
  rows: SalvagedBlockRow[];
  worktreePath: string | null;
  specHash: string | null;
  archiveDir: string;
}

export interface SalvagedRecord {
  salvaged: true;
  salvagedAt: string;
  specHash: string | null;
  spec: null;
  record: OutcomeRecord;
  artifacts: Array<{ blockId: string; name: string; path: string }>;
  skippedArtifacts: ArchiveResult["skipped"];
}

const KNOWN_STATUSES = new Set<BlockStatus>(["green", "failed", "degraded", "stopped", "non-terminal"]);

// An unrecognised status reads as non-terminal, never green. A salvaged run was
// killed, so an unreadable verdict is missing evidence, not a pass.
function toBlockStatus(raw: string): BlockStatus {
  return KNOWN_STATUSES.has(raw as BlockStatus) ? (raw as BlockStatus) : "non-terminal";
}

// `spec` is null on purpose: gate0 persists the spec HASH, not the spec, so a
// salvaged record cannot honestly reproduce it. Consumers that need the spec
// should read it from the launch, and the hash is kept so a mismatch is
// detectable.
export function synthesizeSalvagedRecord(input: SalvageInput): { record: SalvagedRecord; archive: ArchiveResult } {
  const blocks: BlockOutcome[] = input.rows.map((row) => ({
    blockId: row.blockId,
    // The block NAME is not persisted on the row, only the spec-local id.
    block: row.blockId,
    status: toBlockStatus(row.status),
  }));

  const payloads: BlockPayload[] = input.rows.map((row) => ({ blockId: row.blockId, payloadJson: row.payloadJson }));
  const worktree = input.worktreePath;
  const archive = copyArtifacts(
    planArtifactArchive(payloads, input.archiveDir, (candidate) => worktree !== null && isInside(worktree, candidate)),
  );

  return {
    record: {
      salvaged: true,
      salvagedAt: new Date().toISOString(),
      specHash: input.specHash,
      spec: null,
      record: { runId: input.runId, blocks },
      artifacts: archive.copied.map((e) => ({ blockId: e.blockId, name: e.name, path: e.destination })),
      skippedArtifacts: archive.skipped,
    },
    archive,
  };
}

// Prefix containment only — salvage runs after the fact, so the worktree may
// already be gone and realpath would throw on a path that is still worth
// recording as skipped.
function isInside(root: string, candidate: string): boolean {
  const normalizedRoot = root.endsWith("/") ? root : `${root}/`;
  return candidate.startsWith(normalizedRoot);
}
