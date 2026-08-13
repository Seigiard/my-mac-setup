// Catalog emitter (KTD6): renders the block catalog the orchestrator composes
// from. `se blocks --json` runs this; the output is byte-stable so it diffs
// cleanly. The catalog is generated from block definitions, never hand-kept.
import { catalogToJson } from "./lib/block-registry.ts";
import { buildRegistry } from "./lib/blocks/index.ts";

process.stdout.write(catalogToJson(buildRegistry()));
process.stdout.write("\n");
