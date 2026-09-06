// Registration point for the core policies.
//
// Policy modules live beside this file and must never name a client (KTD1);
// the static layering test in tests/agent-hooks-core.test.ts scans this
// directory for client names.
//
// Declaration order is dispatch order (first deny wins). The four policies
// below watch disjoint tools, so the order is presentational today.

import type { Policy } from "../types.ts";
import { fffGrepGuard } from "./fff-grep-guard.ts";
import { testOracleGuard } from "./test-oracle-guard.ts";
import { webfetchMarkdownHint } from "./webfetch-markdown-hint.ts";
import { zshReservedNameGuard } from "./zsh-reserved-name-guard.ts";

export const CORE_POLICIES: Policy[] = [
  testOracleGuard,
  zshReservedNameGuard,
  fffGrepGuard,
  webfetchMarkdownHint,
];
