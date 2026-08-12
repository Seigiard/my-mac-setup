# Global instructions

- Bias: caution over speed on non-trivial work. Use judgment on trivial tasks.

<!-- Writing style rules live in home/.chezmoitemplates/writing-style.md and reach each
     agent natively: Claude output style, pi APPEND_SYSTEM.md, opencode instructions. -->

## Decision-making

### Starting a new user request

Check for project-local instructions: `CLAUDE.local.md`, `AGENTS.local.md`.

Pre-classification triggers (fire in background):

- External library/source mentioned → Agent(`open-source-librarian`)
- 2+ unfamiliar modules, broad codebase question → Agent(subagent_type=Explore)

### Assumptions, pushback, and confusion

- State assumptions explicitly. If uncertain, ask rather than guess.
- Push back when a simpler approach exists.
- Stop when confused. Name what's unclear.

### When to ask the user

Ask ONE clarifying question at a time. Never ask more than one clarifying question at a time.

Ask the user when:

- Multiple interpretations with 2x+ effort difference
- Missing critical info (file, error, context)
- User's design seems flawed
- Script timeout (>2min), sudo needed, or any blocker

### Multi-step tasks

- Define success criteria. Loop until verified.
- Don't follow steps. Define success and iterate.
- After a significant step: summarize what was done, what's verified, what's left.
- Don't continue from a state you can't describe back.

## Skill routing

| Trigger                                 | Skill                                     | Notes                                                                 |
| --------------------------------------- | ----------------------------------------- | --------------------------------------------------------------------- |
| "commit", "create commit"               | `/compound-engineering:ce-commit`         | Let skill handle git                                                  |
| "commit and PR", "push and create PR"   | `/compound-engineering:ce-commit-push-pr` | Full workflow                                                         |
| "review PR", "review code"              | `/se-code-review`                         | Local wrapper: plugin + external reviews                              |
| "simplify", "tidy/refactor branch"      | `/se-simplify`                            | 2 cross-model report legs → single verified apply                     |
| Complex multi-step project starting     | `/compound-engineering:ce-brainstorm`     | Persistent planning                                                   |
| Planning multi-step tasks               | `/se-plan`                                | Local wrapper: plugin plan + external doc review                      |
| Debugging, errors, test failures        | `/compound-engineering:ce-debug`          | Systematic root cause                                                 |
| "review plan", "review spec"            | `/se-doc-review`                          | Local wrapper: plugin + external reviews                              |
| Linear issues, task tracking            | `/linear-cli`                             | Linear CLI management                                                 |
| Linear ticket reference (CORE-XX, etc.) | `/linear-cli` + Linear-first triage       | Fetch ticket BEFORE investigating                                     |
| Plan iteration ("итерация N", "дальше") | Load the plan file first                  | Batch 2–3 units per pass. Gate each batch on a commit.                |
| Migration / refactor                    | `/compound-engineering:ce-work`           | Keep scope fidelity. Never restore code the migration deleted.        |
| Executing work efficiently              | `/compound-engineering:ce-work`           | Quality + completion                                                  |
| "запусти пайплайн", durable plan exec   | `/se-work`                                | se-pipeline, NO plan-review (work→simplify→verify)                    |
| durable exec WITH plan-review first     | `/se-review-and-work`                     | `se-work` + verify-doc; same pipeline, docReview key                  |
| "ask opencode/pi", second opinion       | `/ask-agent`                              | One-shot question to a peer agent; read-only                          |
| "orchestrate agents", durable workflow  | `/smithers`                               | Control plane under se-work and se-plan; use directly for custom runs |

## Working with code

**Editing files**

<important if="you are choosing between writing code and asking a model to reason, for a subtask of your own work or for a step in a system you are building">

- A model suits work with no single correct answer: classification, drafting, summarization, extraction.
- Code suits work that is computable: control flow, retry policy, deterministic transforms, counting, parsing.
- If code can answer, write the code. Do not eyeball a large corpus — measure it.

</important>

<important if="you encounter conflicting patterns or conventions in the codebase">

Pick one (more recent / more tested). Explain why. Flag the other for cleanup.
Don't blend conflicting patterns.

</important>

## GitHub and Linear

**GitHub CLI (`gh`)**

- Prefer `gh pr view`, `gh issue list`, `gh search prs` over `gh api`. Fall back to `gh api` only when the subcommands can't return the data you need.
- `gh` is authed as **Seigiard** (≠ git author "Andrew Borisenko"). PRs open as Seigiard; never request Seigiard as reviewer.

<!-- PR title/description rules moved to ~/.claude/rules/pull-requests.md (auto-loaded, no import needed) -->

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

- `jq` — JSON transforms and parsing
- `rg` with flags (`-t`, `-g`, `--json`) — when specific output format needed
- `fd` — find files by glob, extension, or mtime: `fd -g '<Name>.tsx' <dir>`, `fd -e ts -e tsx . <dir>`, `fd -HI --changed-within 1d . <dir>`. It respects `.gitignore`, so drop the manual `node_modules` exclude chain.
- `magick` — the Read tool cannot open a GIF. Split it into frames: `magick <file>.gif -coalesce frame-%02d.png`. Crop one region: `magick frame-01.png -crop <W>x<H>+<X>+<Y> +repage crop.png`.
- `npx -y agent-browser` — inspect a local dev server, or an app behind PAT auth: `open <url>`, then `snapshot -i`, `eval`, `click @<ref>`, `screenshot <path>`, `close`. Public pages stay with the browser MCP tools and WebFetch.
- Aliases replace `du` with dust and `df` with duf in the agent shell. For POSIX flags write `command du -sh <dir>` and `command df -h <path>`.

**MCP / agent tool selection:**

| Need                              | Primary tool                                                                                                                                                                                                                                                | Fallback                                                                                                                           |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Code search: files and contents   | `mcp__fff__grep` — ONE bare identifier per query. A query with a space returns "0 exact matches". Several identifiers → `mcp__fff__multi_grep`, `patterns` as a JSON array. A file by topic or name → `mcp__fff__find_files`                                | Grep / Glob — for a regex, a quoted string, or a path-scoped search                                                                |
| How an external repo works        | Agent(`open-source-librarian`) — in the background when it precedes planning, blocking when its verdict gates the next step                                                                                                                                 | `mcp__deepwiki__ask_question` for orientation only; confirm every claim with `gh api`                                              |
| Broad question about local code   | Agent(Explore)                                                                                                                                                                                                                                              | Grep by hand                                                                                                                       |
| URL → text                        | `/markdown-new` — clean markdown, no API key, survives JS-heavy SPAs. Use it first for every URL                                                                                                                                                            | `WebFetch`. For several pages in one call: `mcp__jina__read_url` with a URL array — it returns full page text, long pages overflow |
| Web search                        | A named project, library, or error string → `mcp__tavily-mcp__tavily_search`; it wins on niche recall. A broad topic, or when the age of a result matters → `mcp__jina__search_web`; it returns a date field and 9 results per call, tavily returns neither | `WebSearch`                                                                                                                        |
| UI check in the running local app | `mcp__claude-in-chrome__*` — `navigate`, `computer`, and `gif_creator` for a repro GIF                                                                                                                                                                      | `npx -y agent-browser` for a headless check or a screenshot written to a file path                                                 |

**RTK (Rust Token Killer)**

RTK is a token-optimized CLI proxy. A hook rewrites every CLI command (`git status` → `rtk git status`).

RTK truncates search output and shortens paths to an unopenable form (`/.../mod00.ts`). It marks what it dropped (`+33 more files`) and writes the full output to a log file. Read that marker before you conclude a search is complete.

For an exhaustive search, or when you need a path you can open, run the tool unfiltered: `rtk proxy rg ...`, `rtk proxy grep ...`.

@RTK.md
