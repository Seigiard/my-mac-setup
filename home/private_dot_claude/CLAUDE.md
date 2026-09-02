# Global instructions

- Bias: caution over speed on non-trivial work. Use judgment on trivial tasks.

## Decision-making

### Starting a new user request

Check for `AGENTS.local.md`.

Pre-classification triggers (fire in background):

- External library/source mentioned → Agent(`open-source-librarian`)
- 2+ unfamiliar modules, broad codebase question → Agent(subagent_type=Explore)

### Assumptions, pushback, and confusion

- State assumptions explicitly.
- Push back when a simpler approach exists.
- Stop when confused. Name what's unclear.

### When to ask the user

Ask ONE clarifying question at a time.

Ask the user when:

- Multiple interpretations with 2x+ effort difference
- Missing critical info (file, error, context)
- User's design seems flawed
- Script timeout (>2min), sudo needed, or any blocker

### Multi-step tasks

- Define success criteria. Loop until verified.
- After a significant step: summarize what was done, what's verified, what's left.
- Don't continue from a state you can't describe back.

## Skill routing

Every skill's own description already carries its triggers. These four lines resolve what a description cannot:

- **Review, plan, or doc-review → the local `/se-*` wrapper** (`/se-code-review`, `/se-plan`, `/se-doc-review`), never the bare portable `ce-*` original it wraps: same workflow plus independent external Claude and OpenCode legs.
- **Commit, push, PR → `ce-commit` or `ce-commit-push-pr`.** The skill owns every git command; run none of them yourself first.
- **Plan iteration ("итерация N", "дальше") → load the plan file first**, then batch 2–3 units per pass, each batch gated on a commit.
- **Migration or refactor → `ce-work` with scope fidelity:** code the migration deleted stays deleted.

## Working with code

**Editing files**

<important if="you are choosing between writing code and asking a model to reason, for a subtask of your own work or for a step in a system you are building">

- A model suits work with no single correct answer: classification, drafting, summarization, extraction.
- Code suits work that is computable: control flow, retry policy, deterministic transforms, counting, parsing.
- If code can answer, write the code. Do not eyeball a large corpus — measure it.

</important>

<important if="you are adding or reviewing tests, or a skill, plan, or workflow step tells you to write tests">

- **Declare the oracle before the first test edit.** Before the first Edit/Write to any test file, write one line in your visible response naming the consumer, the observable failure, and an oracle independent of the files this patch changes. If you cannot complete the line, write zero new tests and say so. A useful test fails when the protected behavior breaks and stays green through harmless source refactors.
- **This gate outranks every skill's step list.** A "write failing tests first" step in ce-debug, ce-work, or any other workflow does not waive it: a red test proves nothing when its expected value comes from the same patch or inspects source shape. Without the oracle line, the correct output of that step is zero tests.
- Reject expected values copied from source, prompt, config, fixture, or inventory changed by the same patch. Prefer one behavioral, deployment, or validation owner; keep exact text only for externally consumed literal contracts and inventories only when they compare independent sides of a relationship.
- Behavior owned by an upstream system — a tool you route input to, a library you call — has no valid local oracle. Do not reimplement it locally to make it testable; route to its real interface and leave its semantics untested here.
- Removing a dependency, command, config entry, or file does not by itself justify an absence assertion. Test the capability that remains, or exercise the real deployment/runtime transition that clears stale state — never a source grep.

</important>

<important if="the interface, hook, or dispatch point you need does not exist in the system that owns the behavior">

A missing interface is a finding to report, not permission to reimplement the owning system's behavior locally. Stop, name the missing interface, and ask. A local clone of upstream behavior — plus tests for the clone — is the expensive wrong turn.

</important>

<important if="you encounter conflicting patterns or conventions in the codebase">

Pick one (more recent / more tested), state why in one line, and flag the other for cleanup. Every site you touch in this task follows the one you picked.

</important>

## GitHub and Linear

**GitHub CLI (`gh`)**

- Prefer `gh pr view`, `gh issue list`, `gh search prs` over `gh api`. Fall back to `gh api` only when the subcommands can't return the data you need.
- `gh` is authed as **Seigiard** (≠ git author "Andrew Borisenko"). PRs open as Seigiard; never request Seigiard as reviewer.

<important if="user references a ticket ID (CORE-XX, LIN-XX, etc.), asks to fix a bug from an issue tracker, or asks to create a Linear issue">

- Fetch the issue first. Don't start investigation from the user's prompt alone.
- Confirm reproduction steps from the ticket before diving into code.
- If the ticket description and user's request diverge — flag the divergence and ask which to follow.
- Only after ticket + repro are confirmed: proceed to investigation.
- Assign Linear issues to the user by default unless they explicitly request a different assignee.

</important>

## Environment

**Files and shell**

- The permission deny list blocks `Bash(rm -rf:*)`, `Bash(rm -fr:*)`, and `Bash(rm -r:*)`. Recursive delete is not available. Do not look for a flag spelling that gets around it.
- Delete by moving the target into the trash directory `~/.scratchpad`. Run: `mkdir -p ~/.scratchpad && mv <target> ~/.scratchpad/<name>-$(date +%s)`. The timestamp suffix prevents a collision with an earlier move.
- `~/.scratchpad` is the trash directory only. Temporary working files still go to the per-session scratchpad path that the system prompt gives you.
- Nothing empties `~/.scratchpad` automatically. If you moved anything there during a task, say so in your final report and give the user this command: `rm -rf ~/.scratchpad/*`. You cannot run it yourself; the deny list blocks it.
- Monitor/Bash scripts run under zsh, system bash is 3.2: no `declare -A`, no unquoted word-splitting. Use `cmd | while read -r x` + scratchpad state files. After arming a monitor, verify the first event arrives.
- zsh reserves parameter names bash leaves free. Never assign to `status`, `path`, or `argv`: `status=$?` fails *and* leaves `$?` at 1, so the `exit $status` after it reports a fabricated failure for a command that succeeded; `path=`/`argv=` silently destroy PATH and the arguments. Use `rc=$?`. Reading `$status` is fine. The same applies to a one-liner you hand to a herdr pane — the pane is zsh too.

**Long-running work**

<important if="you are about to start, background, or wait on a long-running process — build, test run, dev server, migration, background agent, remote job">

- Read `~/.claude/shared/long-running-work.md` before launching. It carries the supervision contract: completion and progress signals, launch-path verification, observation cadence and the mechanism behind it, stall diagnosis, chosen vs imposed deadlines, ownership of the wait, and escalation when the state cannot be determined.
- The herdr block below decides *where* the process runs when `HERDR_ENV=1`. It does not replace the supervision contract — pane placement comes from herdr, supervision from that document.

</important>

<important if="you are about to start a long-running or observable process — dev server, test watcher, log tail, build — and HERDR_ENV=1 is set">

- You are inside herdr, a terminal multiplexer. The user watches panes, not your background processes.
- Load the `herdr` skill, then run the process in a sibling pane of the current tab. The pane stays visible to the user and survives your session.
- Do not start it as a background Bash process — the user cannot see those.
- Read the process output through the herdr CLI (the skill documents it), not by re-running the command in your own shell.
- Short one-shot commands (a single test run, lint, typecheck) stay in your own Bash tool. Do not create panes for them.
- If HERDR_ENV is not set, this block does not apply; use normal background processes.

</important>

<important if="you are launching background agents or worktree-isolated workers">

- 600s of silent output kills the worker. Stream provisioning (`… 2>&1 | tail -40`), never one silent 10-min command.
- A failed worker's worktree with no tracked edits is auto-cleaned — setup lost. First action = a real tracked edit, then provision.
- Cap concurrent worktree setups at 2–3; 5 parallel `make setup` CPU-starves the machine into watchdog kills.
- For retries after a lost worktree: run in the main checkout on a pre-created branch (deps built, failures don't delete the tree).

</important>

## Tools and search

**CLI tools (via Bash):**

- `fd` — find files by glob, extension, or mtime: `fd -g '<Name>.tsx' <dir>`, `fd -e ts -e tsx . <dir>`, `fd -HI --changed-within 1d . <dir>`. It respects `.gitignore`, so drop the manual `node_modules` exclude chain.
- `magick` — the Read tool cannot open a GIF. Split it into frames: `magick <file>.gif -coalesce frame-%02d.png`. Crop one region: `magick frame-01.png -crop <W>x<H>+<X>+<Y> +repage crop.png`.
- `npx -y agent-browser` — inspect a local dev server, or an app behind PAT auth: `open <url>`, then `snapshot -i`, `eval`, `click @<ref>`, `screenshot <path>`, `close`. Public pages stay with the browser MCP tools and WebFetch.
- Aliases replace `du` with dust and `df` with duf in the agent shell. For POSIX flags write `command du -sh <dir>` and `command df -h <path>`.

**MCP / agent tool selection:**

| Need                              | Primary tool                                                                                                                                                                                                                                                | Fallback                                                                                                                           |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Code search: files and contents   | `mcp__fff__grep` (the server's own instructions carry its query rules)                                                                                                                                                                                       | Grep / Glob — for a regex, a quoted string, or a path-scoped search                                                                |
| How an external repo works        | Agent(`open-source-librarian`) — in the background when it precedes planning, blocking when its verdict gates the next step                                                                                                                                 | `mcp__deepwiki__ask_question` for orientation only; confirm every claim with `gh api`                                              |
| Broad question about local code   | Agent(Explore)                                                                                                                                                                                                                                              | Grep by hand                                                                                                                       |
| URL → text                        | `/markdown-new` — clean markdown, no API key, survives JS-heavy SPAs. Use it first for every URL                                                                                                                                                            | `WebFetch`. For several pages in one call: `mcp__jina__read_url` with a URL array — it returns full page text, long pages overflow |
| Web search                        | A named project, library, or error string → `mcp__tavily-mcp__tavily_search`; it wins on niche recall. A broad topic, or when the age of a result matters → `mcp__jina__search_web`; it returns a date field and 9 results per call, tavily returns neither | `WebSearch`                                                                                                                        |
| UI check in the running local app | `mcp__claude-in-chrome__*` — `navigate`, `computer`, and `gif_creator` for a repro GIF                                                                                                                                                                      | `npx -y agent-browser` for a headless check or a screenshot written to a file path                                                 |
