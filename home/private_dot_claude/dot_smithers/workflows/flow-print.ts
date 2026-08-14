// Flow printout (R10): renders a validated spec as an ordered block list with
// a cost estimate, so `se flow` can show what a launch will run before it runs.
// Validation happens here too — printing a spec the interpreter would refuse at
// gate-0 would tell the operator a launch is coming that cannot start.
import * as fs from "node:fs";

import { buildRegistry } from "./lib/blocks/index.ts";
import { formatFlowPlan } from "./lib/flow-run.ts";
import { validateFlowSpec } from "./lib/flow-validate.ts";

const specPath = process.argv[2];
if (!specPath) {
  process.stderr.write("flow-print: expected a spec path\n");
  process.exit(2);
}

const raw = JSON.parse(fs.readFileSync(specPath, "utf8")) as unknown;
const registry = buildRegistry();
const result = validateFlowSpec(raw, { registry: registry.view(), archiveExists: (id) => fs.existsSync(id) });

if (!result.ok) {
  process.stderr.write("flow-print: spec is invalid, the interpreter would refuse it at gate-0:\n");
  for (const error of result.errors) {
    const where = error.blockId ? ` [${error.blockId}]` : "";
    process.stderr.write(`  ${error.invariant}${where}: ${error.hint}\n`);
  }
  process.exit(1);
}

const plan = formatFlowPlan(result.spec.task.description, result.spec.blocks, (name) => {
  const def = registry.get(name);
  return def ? { estUsd: def.costProfile.estUsd, kind: def.kind } : undefined;
});
process.stdout.write(`${plan}\n`);
