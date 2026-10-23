// Registration point for the core policies.
//
// Policy modules live beside this file and must never name a client (KTD1);
// the static layering test in tests/agent-hooks-core.test.ts scans this
// directory for client names.
//
// Declaration order is dispatch order (first deny wins). The bash policies
// share a tool, so the setup guard stays after the zsh guard intentionally.

import type { Policy } from "../types.ts";
import { agentDocWritingHint } from "./agent-doc-writing-hint.ts";
import { fffGrepGuard } from "./fff-grep-guard.ts";
import { webfetchMarkdownHint } from "./webfetch-markdown-hint.ts";
import { zshReservedNameGuard } from "./zsh-reserved-name-guard.ts";
import { worktreeSetupGuard } from "./worktree-setup-guard.ts";
import { worktreeSetupStuckHint } from "./worktree-setup-stuck-hint.ts";

export const CORE_POLICIES: Policy[] = [
  zshReservedNameGuard,
  fffGrepGuard,
  worktreeSetupGuard,
  webfetchMarkdownHint,
  agentDocWritingHint,
  worktreeSetupStuckHint,
];
