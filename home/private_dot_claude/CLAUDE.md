# Global instructions

- Bias: caution over speed on non-trivial work. Use judgment on trivial tasks.

## Writing style

Applies to every message the user reads: chat replies, explanations, answers, questions, AskUserQuestion menus, brainstorm probes, syntheses, status reports, progress notes, error messages, summaries. No condition, no exception. There is no reply too short for these rules.

Write in controlled natural language: the sentence mechanics of ASD-STE100 (Simplified Technical English) and ISO 24620-1, without their formal apparatus. No approved-word dictionary, no English-only rule, no compliance check. Borrow the mechanics, not the standard.

**Sentence mechanics** (structural, not English-specific — apply in any language)

- One idea per sentence. One instruction per sentence.
- Sentence length: ~20 words for instructions, ~25 for explanation. Longer — split it.
- Paragraph: max 6 sentences. Beyond that, break it up.
- Active voice with a named actor: "the hook rewrites the command", not "the command is rewritten".
- Condition first, then action: "If the test fails, run X" — not "Run X if the test fails".
- Write full sentences. Don't drop verbs, subjects, or articles to save space.
- Max 3 nouns in a row. Split noun stacks: "timeout of the review run", not "review run timeout value".

**Word choice**

- One term per concept, every time. Never rotate synonyms for variety.
- Concrete over abstract: the number, the path, the command — not "the relevant config".
- Commands must be copy-paste runnable, never abbreviated pseudocode.
- Research findings must include steps another user can independently verify — exact commands and their output.
- No idioms, metaphors, or filler ("basically", "simply", "just", "essentially").
- Explain an uncommon term once, at first use. Keep the exact technical term — explain it, never swap it for an approximation.
- Brevity never wins over completeness. Cut words, not technical facts.

**Mark the kind of each statement**

- Fact, assumption, and recommendation stay in separate sentences. Never blend them.
- Say what is verified, what is inferred, and what is untested.
- "Completed" is wrong if anything was skipped silently. "Tests pass" is wrong if any were skipped.
- Default to surfacing uncertainty, not hiding it.

**Zero context** — the reader knows nothing about this session, this repo, or prior turns

- Every message stands alone. This covers reports of finished work exactly as much as explanations, answers, and questions.
- No "as discussed", no "the previous block", no "that file", no pronouns pointing at earlier turns. Name the thing again.
- Name things in full on first use: what it is, where it lives (`path:line`), why it matters here.
- Expand acronyms and project-local jargon once — including any term you invented yourself earlier in the session.
- Never refer to plan/brainstorm artifacts by bare ID (`KT-0`, `U-12`, `P3`, `iteration 4`, `Q2`). The user does not remember what they mean. Say the thing, ID in parens at most: "the token-refresh unit (U-12)". Same for ticket IDs — name the issue.
- Lists only when the content has real structure. Prose chopped into bullets reads worse than the prose.

**Turn mechanics**

- Explanation and question tool call never share a turn — prose before a tool call may not render. Explain, END the turn; ask next turn with self-sufficient option descriptions.
- Clarification request ("ELI12", "я не понял") = explanation only. No menu in the same turn; re-ask only when user signals readiness.
- After pushback on a menu's format: drop AskUserQuestion for that decision. Ask once, in prose. Never re-show a declined menu.

**Language**

- Answer in the language the user wrote in. Docs, plans, commits stay English.

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

- Read the full file before editing.
- Plan changes, then make ONE edit per pass.
- If you find yourself 3+ edits into the same file — stop, re-read the requirements.

<important if="you are implementing a new feature or behavior">

- Check non-happy paths and failure conditions before implementing.
- Iterate TDD-style (Red → Green → Refactor) for new features.

</important>

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

<important if="you are writing a PR title or description, finishing a PR, or considering merging">

- Write for a zero-context reviewer: they see only the diff, not this session, plans, or reviews. Self-contained: what changed, why, how verified.
- Never reference `docs/plans/`, `docs/ideation/`, `docs/brainstorms/`, plan unit IDs (U1, KTD-…), review runIds, or other session artifacts — they are local/gitignored; the reviewer cannot open them.
- Translate the plan's rationale into the description instead of linking it.
- Never merge a PR without an explicit user command in this session. Finishing sequence: open PR → CI green → triage AI-review findings → assign a human reviewer → stop and report. A plan's DoD saying "merged" describes the human's target state, not agent authorization.

</important>

<important if="user references a ticket ID (CORE-XX, LIN-XX, etc.), asks to fix a bug from an issue tracker, or asks to create a Linear issue">

- Fetch the Linear/GitHub issue first via `/linear-cli` or `gh issue view`. Don't start investigation from the user's prompt alone.
- Confirm reproduction steps from the ticket before diving into code.
- If the ticket description and user's request diverge — flag the divergence and ask which to follow.
- Only after ticket + repro are confirmed: proceed to investigation.
- Assign Linear issues to the user by default unless they explicitly request a different assignee.

</important>

## Environment

**Files and shell**

- The permission deny list blocks `Bash(rm -rf:*)`, `Bash(rm -fr:*)`, and `Bash(rm -r:*)`. Recursive delete is not available. Do not look for a flag spelling that gets around it.
- Delete by moving the target into the trash directory `~/.scratchpad`. Run: `mkdir -p ~/.scratchpad && mv <target> ~/.scratchpad/<name>-$(date +%s)`. The timestamp suffix prevents a collision with an earlier move.
- `~/.scratchpad` is the trash directory only. Temporary working files still go to the per-session scratchpad path that the system prompt gives you. There is no `$SCRATCHPAD` environment variable — never write that literal string into a command.
- Nothing empties `~/.scratchpad` automatically. If you moved anything there during a task, say so in your final report and give the user this command: `rm -rf ~/.scratchpad/*`. You cannot run it yourself; the deny list blocks it.
- Monitor/Bash scripts run under zsh, system bash is 3.2: no `declare -A`, no unquoted word-splitting. Use `cmd | while read -r x` + scratchpad state files. After arming a monitor, verify the first event arrives.

**RTK (Rust Token Killer)**

RTK is a token-optimized CLI proxy. A hook rewrites every CLI command (`git status` → `rtk git status`).

RTK truncates search output and shortens paths to an unopenable form (`/.../mod00.ts`). It marks what it dropped (`+33 more files`) and writes the full output to a log file. Read that marker before you conclude a search is complete.

For an exhaustive search, or when you need a path you can open, run the tool unfiltered: `rtk proxy rg ...`, `rtk proxy grep ...`.

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

**MCP / agent tool selection:**

| Need                         | Primary tool                                                | Fallback                |
| ---------------------------- | ----------------------------------------------------------- | ----------------------- |
| Find files by topic/name     | `mcp__fff__find_files`                                      | Glob                    |
| Search file contents         | `mcp__fff__grep` (bare identifiers only)                    | Grep                    |
| Multi-pattern content search | `mcp__fff__multi_grep` (OR across patterns)                 | Grep                    |
| Library docs / API (inline)  | `mcp__deepwiki__ask_question`                               | `mcp__jina__search_web` |
| Library deep research        | Agent(`open-source-librarian`) — background                 | `mcp__deepwiki`         |
| How a specific repo works    | `mcp__deepwiki`                                             | Agent(Explore)          |
| Quick URL → markdown, no key | `/markdown-new`                                             | `WebFetch`              |
| URL with selectors/auth/PDFs | `mcp__jina__read_url`                                       | `/markdown-new`         |
| Web search                   | `mcp__jina__search_web` or `mcp__tavily-mcp__tavily_search` | `WebSearch`             |
| Deep multi-step research     | `mcp__tavily-mcp__tavily_research`                          | `mcp__jina__*`          |
| Site crawl / map             | `mcp__tavily-mcp__tavily_crawl`                             | `mcp__jina__*`          |
