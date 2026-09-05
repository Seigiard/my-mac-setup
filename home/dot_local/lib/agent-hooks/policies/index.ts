// Registration point for the core policies.
//
// Policy modules live beside this file and must never name a client (KTD1);
// the static layering test in tests/agent-hooks-core.test.ts scans this
// directory for client names.

import type { Policy } from "../types.ts";

export const CORE_POLICIES: Policy[] = [];
