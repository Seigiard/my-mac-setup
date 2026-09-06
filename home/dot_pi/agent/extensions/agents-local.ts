// @ts-nocheck
// Type checking is off here for the same reason the other managed pi
// extensions turn it off: this file is checked out in a plain dotfiles repo
// with no node_modules, and only resolves its imports once deployed under
// ~/.pi/agent/, where pi's own runtime resolves them.

import { join } from "node:path";

// pi transport for the shared local-instructions module.
//
// Selection, the symlink-escape check, the size cap and the emitted block all
// live in ~/.local/lib/agent-hooks/local-instructions.ts and are shared with
// the opencode plugin, so the safety checks exist once (R7). What stays here
// is pi-specific: the once-per-cwd ui.notify warning, which has no opencode
// equivalent (KTD11).
//
// Relative imports cannot span the two deploy roots, so the path is absolute
// (KTD5). A load-time failure registers no handler: silently adding no local
// instructions is the honest degradation, and a registered handler that always
// returned undefined would look alive to a reader.

const HOME = process.env.HOME ?? "";
const MODULE_PATH = join(HOME, ".local", "lib", "agent-hooks", "local-instructions.ts");

let buildLocalInstructions: ((cwd: string) => Promise<{ block?: string; warnings: string[] }>) | undefined;
try {
  ({ buildLocalInstructions } = await import(MODULE_PATH));
} catch {
  buildLocalInstructions = undefined;
}

const warnedKeys = new Set<string>();

function notifyWarningsOnce(ctx, warnings: string[]): void {
  if (!ctx.hasUI) return;
  for (const warning of warnings) {
    const key = `${ctx.cwd}:${warning}`;
    if (warnedKeys.has(key)) continue;
    warnedKeys.add(key);
    ctx.ui.notify(warning, "warning");
  }
}

export default function agentsLocalExtension(pi): void {
  if (!buildLocalInstructions) return;

  pi.on("before_agent_start", async (event, ctx) => {
    let block: string | undefined;
    let warnings: string[] = [];
    try {
      ({ block, warnings } = await buildLocalInstructions(ctx.cwd));
    } catch {
      // A selection that throws leaves the prompt exactly as pi built it;
      // local instructions are additive, so degrading to none is safe (R4).
      return undefined;
    }
    notifyWarningsOnce(ctx, warnings);
    if (!block) return undefined;

    return {
      systemPrompt: event.systemPrompt + block,
    };
  });
}
