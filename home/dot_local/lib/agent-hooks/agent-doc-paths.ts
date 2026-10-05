// The path vocabulary that says whether a file is prose an agent reads.
//
// Boundary (KTD1): the dispatch core's layering rule bans client names from
// `policies/`, because that is where applicability used to get hardcoded. This
// module is not applicability — it is subject matter. An agent instruction
// file is named CLAUDE.md or AGENTS.md, and a client keeps its commands in a
// directory named after itself; a vocabulary that recognises those files has
// no spelling that avoids the names. So it sits in the lib root beside
// local-instructions.ts, which names the same files for the same reason, and
// the policy that consumes it stays free of them.
//
// Both the deployed path and the chezmoi source spelling are listed. An edit
// is made in the source tree, where the live path does not exist yet, and the
// hint has to reach the file being written rather than the file it becomes.

/** Prose extensions. A settings.json or a hook script is not this vocabulary's business. */
const PROSE = /\.(md|mdc|txt)(\.tmpl)?$/;

/** The instruction files every client here reads, plus their local overlays. */
const INSTRUCTION_FILE = /^(CLAUDE|AGENTS)(\.local)?\.md(\.tmpl)?$/;

/** A skill's own entry point, including the chezmoi symlink spelling. */
const SKILL_ENTRY = /^(symlink_)?SKILL\.md(\.tmpl)?$/;

/** The canonical halves of an explicit-only workflow, kept in .chezmoitemplates. */
const EXPLICIT_ONLY = /^explicit-only-.+\.(md|txt)$/;

/** Directories whose markdown is written for an agent rather than for a reader. */
const AGENT_TREES = [
  "/.claude/",
  "/private_dot_claude/",
  "/.agents/",
  "/private_dot_agents/",
  "/.codex/",
  "/private_dot_codex/",
  "/.pi/agent/",
  "/dot_pi/agent/",
  "/skills/",
  "/opencode/commands/",
  "/opencode/skills/",
];

function basenameOf(filePath: string): string {
  const cut = filePath.lastIndexOf("/");

  return cut === -1 ? filePath : filePath.slice(cut + 1);
}

export function isAgentDoc(filePath: string): boolean {
  if (filePath === "") return false;
  const basename = basenameOf(filePath);

  if (INSTRUCTION_FILE.test(basename)) return true;

  if (SKILL_ENTRY.test(basename)) return true;

  if (EXPLICIT_ONLY.test(basename)) return true;

  if (!PROSE.test(basename)) return false;

  return AGENT_TREES.some((tree) => filePath.includes(tree));
}
