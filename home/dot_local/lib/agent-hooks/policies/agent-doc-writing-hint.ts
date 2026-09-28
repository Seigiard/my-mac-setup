// Reminder that an agent-facing document is under the pen.
//
// The `writing-for-agents` skill already names its own targets in its
// description, but a description is a soft trigger: it fires only when the
// model happens to weigh it, which in practice meant asking for the skill by
// name on most of these edits. This policy makes the trigger mechanical
// instead, at the moment the edit is proposed.
//
// It never blocks. A rename, a frontmatter tweak or a path fix inside one of
// these files is a legitimate edit that owes nothing to the skill, and this
// route cannot tell those from prose. So its only outcome is `context`, which
// also confines it to the one client whose transport can carry additional
// context — derived in the registry, never named here.
//
// Which paths count is vocabulary, not dispatch, and lives in
// ../agent-doc-paths.ts; that module documents why.

import { isAgentDoc } from "../agent-doc-paths.ts";
import type { Decision, NormalizedEvent, Policy } from "../types.ts";
import { ALLOW, context } from "../types.ts";

const NAME = "agent-doc-writing-hint";

const HINT =
  "Reminder: this file is a document an agent reads, so the `writing-for-agents` skill governs its prose. Read the skill before writing or rewriting prose here. Skip it for an edit that touches no prose: a rename, a path fix, a frontmatter field.";

function evaluate(event: NormalizedEvent): Decision {
  return isAgentDoc(event.filePath) ? context(HINT) : ALLOW;
}

export const agentDocWritingHint: Policy = {
  name: NAME,
  tools: ["edit", "write"],
  outcomes: ["context"],
  evaluate,
};
