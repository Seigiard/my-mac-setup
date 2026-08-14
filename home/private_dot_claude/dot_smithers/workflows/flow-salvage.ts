// `se flow salvage <runId>` (U5/KTD10): rebuild an outcome archive for a run
// that never reached its epilog, from the block rows already in smithers.db.
// Prints the archive directory on stdout so it can be fed straight to a later
// spec's `artifactsFrom`.
//
// Refuses to overwrite an existing record: a run that DID reach its epilog has
// an authoritative record, and replacing it with a synthesized one would trade
// real evidence for a reconstruction.
import { Database } from "bun:sqlite";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import { redactSecretsInText } from "./lib/issue-writer.ts";
import { synthesizeSalvagedRecord, type SalvagedBlockRow } from "./lib/salvage.ts";

const runId = process.argv[2];
const dbPath = process.argv[3];
if (!runId || !dbPath) {
  process.stderr.write("flow-salvage: expected <runId> <db-path>\n");
  process.exit(2);
}

if (!fs.existsSync(dbPath)) {
  process.stderr.write(`flow-salvage: no smithers database at ${dbPath}\n`);
  process.exit(1);
}

const archiveDir = path.join(os.tmpdir(), "se-flow", runId);
const recordPath = path.join(archiveDir, "outcome.json");
if (fs.existsSync(recordPath)) {
  const already = JSON.parse(fs.readFileSync(recordPath, "utf8")) as { salvaged?: boolean };
  process.stderr.write(
    already.salvaged === true
      ? `flow-salvage: ${runId} was already salvaged — keeping the existing record\n`
      : `flow-salvage: ${runId} already has an outcome record from its own epilog — that record is authoritative, nothing to salvage\n`,
  );
  process.stdout.write(`${archiveDir}\n`);
  process.exit(0);
}

const db = new Database(dbPath, { readonly: true });
let rows: SalvagedBlockRow[];
let worktreePath: string | null;
let specHash: string | null;
try {
  rows = (db.query("SELECT block_id, status, payload_json FROM block_output WHERE run_id = ?1").all(runId) as Array<{
    block_id: string;
    status: string;
    payload_json: string;
  }>).map((r) => ({ blockId: r.block_id, status: r.status, payloadJson: r.payload_json }));

  const staging = db.query("SELECT worktree_path FROM staging WHERE run_id = ?1 LIMIT 1").get(runId) as { worktree_path?: string } | null;
  worktreePath = staging?.worktree_path ?? null;

  const gate0 = db.query("SELECT spec_hash FROM gate0 WHERE run_id = ?1 LIMIT 1").get(runId) as { spec_hash?: string } | null;
  specHash = gate0?.spec_hash ?? null;
} finally {
  db.close();
}

if (rows.length === 0) {
  process.stderr.write(`flow-salvage: ${runId} has no recorded block rows — it was killed before any block finished, so there is nothing to salvage\n`);
  process.exit(1);
}

fs.mkdirSync(archiveDir, { recursive: true });
const { record, archive } = synthesizeSalvagedRecord({ runId, rows, worktreePath, specHash, archiveDir });
// Same publication-time redaction the epilog applies (KTD13b): a salvaged
// record is written to disk exactly like a normal one.
const { redacted, hits } = redactSecretsInText(JSON.stringify(record, null, 2));
fs.writeFileSync(recordPath, redacted);

process.stderr.write(
  `flow-salvage: ${runId} — ${rows.length} block row(s), ${archive.copied.length} artifact(s) copied, ${archive.skipped.length} skipped${hits.length > 0 ? `, ${hits.length} secret(s) redacted` : ""}\n`,
);
if (worktreePath === null) {
  process.stderr.write("flow-salvage: no staging row, so no artifacts could be recovered — the run died before staging\n");
} else if (!fs.existsSync(worktreePath)) {
  process.stderr.write(`flow-salvage: worktree ${worktreePath} is gone, so only the block statuses were recoverable\n`);
}
process.stdout.write(`${archiveDir}\n`);
