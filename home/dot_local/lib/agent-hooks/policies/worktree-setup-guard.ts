// Gate commands that would race the dependency setup of a new worktree.

import { isRecoveryCommand, isSetupCommand } from "../setup-commands.ts";
import type { Decision, NormalizedEvent, Policy, SetupState } from "../types.ts";
import { ALLOW, block } from "../types.ts";

const NAME = "worktree-setup-guard";

const RECOVERY_COMMAND = "mise exec -- make setup";

const FIVE_MINUTES_MS = 5 * 60 * 1000;

const CANARY_SETUP: SetupState = { status: "done", exit: 7, alreadyDenied: false };

function evaluate(event: NormalizedEvent): Decision {
  if (!isSetupCommand(event.command)) return ALLOW;

  const setup = event.setup;

  if (setup === undefined || setup.status === "absent" || setup.status === "unknown") return ALLOW;

  if (setup.status === "running") {
    if (!setup.alive) {
      if (setup.alreadyDenied || isRecoveryCommand(event.command)) return ALLOW;

      return block(`${NAME}: worktree setup was interrupted; run \`${RECOVERY_COMMAND}\`. If that also fails, report and stop.`);
    }

    if (setup.elapsedMs >= FIVE_MINUTES_MS) return ALLOW;

    return block(`${NAME}: worktree setup is running for ${Math.floor(setup.elapsedMs / 1000)} s; wait and retry.`);
  }

  if (setup.exit === 0 || setup.alreadyDenied || isRecoveryCommand(event.command)) return ALLOW;

  return block(`${NAME}: setup failed with ${setup.exit}; run \`${RECOVERY_COMMAND}\`. If that also fails, report and stop.`);
}

export const worktreeSetupGuard: Policy = {
  name: NAME,
  tools: ["bash"],
  outcomes: ["block"],
  canary: { tool: "bash", payload: { command: "make test" } },
  canarySetup: CANARY_SETUP,
  evaluate,
};
