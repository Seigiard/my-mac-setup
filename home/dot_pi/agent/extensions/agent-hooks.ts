// @ts-nocheck
// Type checking is off here for the same reason the other managed pi
// extensions turn it off: this file is checked out in a plain dotfiles repo
// with no node_modules, and only resolves its imports once deployed under
// ~/.pi/agent/, where pi's own runtime resolves them.

import { join } from "node:path";

// pi transport for the shared agent-hooks dispatch core.
//
// Every policy lives in ~/.local/lib/agent-hooks; this file only translates.
// In: pi's tool_call event is already the core's pi dialect ({toolName, input}),
// so the event goes through untouched. Out: a deny is `{block: true, reason}`
// carrying the core's already-prefixed reason; an allow is a bare return.
//
// Fails open in every direction (R4): no core on disk, a core that will not
// import, or a dispatch that throws must all let the tool call proceed.

const CLIENT = "pi";
const HOME = process.env.HOME ?? "";
const CORE_DIR = join(HOME, ".local", "lib", "agent-hooks");

// Load-time import rather than per-call (KTD5): a failure is front-loaded into
// an extension that registers nothing, which is the honest fail-open shape — an
// installed handler that silently allows would look alive to a reader. It also
// keeps the handler body synchronous, so the deny does not depend on pi
// awaiting it. (pi 0.84.4 does await a promise-returning tool_call handler and
// honours the block it resolves to — verified with a scratch extension — but
// the core needs nothing from that.)
let dispatch: ((client: string, rawEvent: unknown) => any) | undefined;
try {
  ({ dispatch } = await import(join(CORE_DIR, "index.ts")));
} catch {
  dispatch = undefined;
}

// The marker records which core this resident session actually loaded, so
// selfcheck can tell a stale session from a current one after an apply (KTD5).
// Best-effort and separate from the gate above: no marker is a reporting gap,
// not a reason to stop enforcing.
if (dispatch && HOME !== "") {
  try {
    const { writeMarker } = await import(join(CORE_DIR, "selfcheck.ts"));
    writeMarker(CLIENT, { stateDir: join(HOME, ".local", "state", "agent-hooks") });
  } catch {
    // A marker this session cannot write leaves its identity unknown, which is
    // what selfcheck already reports for a session it has no evidence about.
  }
}

export default function (pi) {
  if (!dispatch) return;

  pi.on("tool_call", (event) => {
    let decision: any;
    try {
      decision = dispatch(CLIENT, event);
    } catch {
      // Deliberately wider than the return below: a throw out of this handler
      // is not a deny in pi's contract, and guessing which throws were meant
      // as denies is what the retired per-policy adapters had to do.
      return;
    }
    if (decision?.verdict === "block") return { block: true, reason: decision.reason };
  });
}
