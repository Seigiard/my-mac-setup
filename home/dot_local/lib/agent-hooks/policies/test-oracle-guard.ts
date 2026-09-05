// Negative-assertion gate for proposed edits to test files.
//
// A test that asserts the ABSENCE of a string usually restates the patch that
// removed it instead of protecting behavior (the standard this enforces lives
// in docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md).
// The gate fires only on test files and only on negative-assertion patterns, so
// a clean edit costs the calling agent zero context.

import type { Decision, NormalizedEvent, Policy } from "../types.ts";
import { ALLOW, block } from "../types.ts";

const NAME = "test-oracle-guard";

/** A comment carrying this token names the independent oracle for the line. */
const ESCAPE_HATCH = "oracle:";

/** The escape covers the flagged line itself plus the three lines above it. */
const ESCAPE_WINDOW = 3;

const TEST_DIRECTORIES = ["tests", "test", "__tests__"];

const NEGATIVE_ASSERTION =
  /assert_not_contains|assert_file_not_contains|assert_not_matches|refute_match|refute_includes|not\.tocontain|not\.tomatch|not_to include|not_to match|! grep /;

const ADVICE =
  'An absence assertion usually restates the patch that removed the string instead of protecting behavior. Before keeping it, name three things: the consumer, the observable failure, and an oracle independent of the files this patch changes. Prefer testing the capability that remains, or the real deployment/runtime transition that clears stale state. If this negative assertion is genuinely load-bearing, add a comment naming the oracle (the comment must contain "oracle:") on the line above it and retry.';

function isTestPath(path: string): boolean {
  for (const directory of TEST_DIRECTORIES) {
    if (path.includes(`/${directory}/`) || path.startsWith(`${directory}/`)) return true;
  }
  const basename = path.slice(path.lastIndexOf("/") + 1);
  return (
    basename.includes("_test.") ||
    basename.startsWith("test_") ||
    basename.includes(".test.") ||
    basename.includes(".spec.") ||
    basename.includes("_spec.")
  );
}

function flaggedLines(content: string): string[] {
  const flagged: string[] = [];
  let lastEscape = 0;

  content.split("\n").forEach((line, index) => {
    const number = index + 1;
    const lowered = line.toLowerCase();
    // Checked before the assertion test, so a token on the flagged line counts.
    if (lowered.includes(ESCAPE_HATCH)) lastEscape = number;
    if (!NEGATIVE_ASSERTION.test(lowered)) return;
    if (lastEscape === 0 || number - lastEscape > ESCAPE_WINDOW) {
      flagged.push(`  line ${number}: ${line}`);
    }
  });

  return flagged;
}

function evaluate(event: NormalizedEvent): Decision {
  const path = event.filePath;
  if (path === "" || !isTestPath(path)) return ALLOW;

  const flagged = flaggedLines(event.content);
  if (flagged.length === 0) return ALLOW;

  return block(
    [`${NAME}: negative assertion(s) without a named oracle in ${path}:`, ...flagged, ADVICE].join("\n"),
  );
}

export const testOracleGuard: Policy = {
  name: NAME,
  tools: ["edit", "write"],
  outcomes: ["block"],
  escapeHatch: ESCAPE_HATCH,
  canary: {
    tool: "write",
    payload: {
      filePath: "tests/agent-hooks/canary_test.sh",
      content: 'assert_not_contains "$rendered" "retired-flag"',
    },
  },
  evaluate,
};
