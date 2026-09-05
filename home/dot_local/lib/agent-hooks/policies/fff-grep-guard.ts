// Query-shape gate for the fff grep tool.
//
// fff grep matches one literal line, so a query of several bare words finds
// nothing. Measured over 1736 past sessions: 74 of 146 calls were multi-token
// and 49 of those returned "0 exact matches". The multi-token calls that did
// work were path-scoped ("KnowledgeContextField console/"), so path and glob
// tokens are not counted here.

import type { Decision, NormalizedEvent, Policy } from "../types.ts";
import { ALLOW, block } from "../types.ts";

const NAME = "fff-grep-guard";

/** Tokens carrying either character scope the search and are not counted. */
const SCOPING_CHARACTERS = ["/", "*"];

const MAX_BARE_TOKENS = 1;

function bareTokenCount(query: string): number {
  return query
    .split(/\s/)
    .filter((token) => token !== "")
    .filter((token) => !SCOPING_CHARACTERS.some((character) => token.includes(character))).length;
}

function evaluate(event: NormalizedEvent): Decision {
  const query = event.query;
  if (query === "") return ALLOW;
  if (bareTokenCount(query) <= MAX_BARE_TOKENS) return ALLOW;

  return block(
    `${NAME}: fff grep matches ONE literal line, so the query '${query}' will return "0 exact matches". ` +
      `Pick one: search a single identifier with mcp__fff__grep; search several identifiers with ` +
      `mcp__fff__multi_grep and a JSON array of patterns; or use the built-in Grep for a regex or a ` +
      `quoted phrase. Adding a path token such as 'console/' also passes this guard.`,
  );
}

export const fffGrepGuard: Policy = {
  name: NAME,
  tools: ["fff-grep"],
  outcomes: ["block"],
  canary: { tool: "fff-grep", payload: { query: "KnowledgeContextField console" } },
  evaluate,
};
