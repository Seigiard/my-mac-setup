// Tell the agent when setup has exceeded the normal five-minute window.

import { isSetupCommand } from "../setup-commands.ts";
import type { Decision, NormalizedEvent, Policy } from "../types.ts";
import { ALLOW, context } from "../types.ts";

const NAME = "worktree-setup-stuck-hint";

const FIVE_MINUTES_MS = 5 * 60 * 1000;

function evaluate(event: NormalizedEvent): Decision {
  const setup = event.setup;

  if (
    !isSetupCommand(event.command) ||
    setup === undefined ||
    setup.status !== "running" ||
    !setup.alive ||
    setup.elapsedMs < FIVE_MINUTES_MS
  ) {
    return ALLOW;
  }

  return context(`${NAME}: worktree setup looks stuck after ${Math.floor(setup.elapsedMs / 1000)} s; the command will run.`);
}

export const worktreeSetupStuckHint: Policy = {
  name: NAME,
  tools: ["bash"],
  outcomes: ["context"],
  evaluate,
};
