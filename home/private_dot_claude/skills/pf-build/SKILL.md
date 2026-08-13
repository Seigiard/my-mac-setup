---
name: cast
description: Cast an inscribed spell — implement the open inscription PR's contract deltas in real code by dispatching a headless opencode session per sub-task, reviewing and auto-merging each implementation PR into the inscription branch, and proving the result live with a demo plus a discrepancy report; the user performs the cycle's single merge to main. Third spell of the /divine → /inscribe → /cast cycle. Use when the user says "cast <epic-or-topic>" or wants an approved inscription implemented; a small, self-contained change may run as a direct cast with no inscription.
argument-hint: "<epic-or-topic>"
---

# /cast — implement the inscription and prove it live

Cast an inscribed spell: implement the open **inscription PR**'s contract deltas in real code — slice the work into local sub-task files, dispatch a headless opencode session per sub-task, review each PR against its deltas and validation criteria, fix or feed back corrections, and auto-merge each implementation PR **into the inscription branch** (never to main). The casting ends with a **demo**: a walkthrough of the new functionality in the real product, validated live, with a discrepancy report against the inscription — and one big PR the user reviews and merges as the cycle's single merge to main. Third spell of the `/divine` → `/inscribe` → `/cast` cycle (shared mechanics: read `~/.claude/grimoire.md` first). You are the caster and the only human-facing party; task management stays in the artifact directory's `tasks/` files (grimoire → Linear is opt-in — mirror to Linear sub-issues only when the user explicitly asks).

Invoked as `/cast <epic-or-topic>` (the artifact directory's id: a topic slug, or a Linear identifier like PRD-1234 when an epic exists). If none is given, use the one from the current conversation. Cast can also run as a **direct cast** — with no inscription — when the user asks for that or the change is small and self-contained; see **Two ways to cast** below. That is a valid, first-class way to cast, not a shortcut to apologize for.

## Two ways to cast

**Inscription-based (the default, everything below).** The full cycle: an open inscription PR is the target, children merge into its branch, local task files track the sub-tasks, and the child-CI caveat, watcher, and heartbeat all apply. Every section after this one assumes this mode.

**Direct cast (no inscription).** When the user invokes `/cast` and asks to skip inscribing, or the change is small and self-contained enough that a spec-and-sub-task ceremony is pure overhead, cast direct:

- **The spec is the divination (or the change the user described), written to a canonical local plan file** (`~/.claude/artifacts/<topic>/plan.md` or scratchpad) — no sub-task files, nothing to round-trip.
- **Contracts and code ship together, in the implementation PR(s) based on `main`** — there is no separate inscription PR. Follow each affected `contracts/<name>.md`'s "Making Changes", rebuild touched artifacts (`bun run contracts:build:<name>`), and commit them with the code. If there is genuinely no contract delta, it's a plain feature branch — never invent surface to satisfy ceremony.
- **Slice only if scale genuinely demands it.** A contained change is one coherent PR — implement it directly, or dispatch a single opencode session (still the preferred way to originate implementation). Reserve multi-PR fan-out for large work, and track those slices in the local plan file.
- **Because the PR base is `main`, real CI runs** — the child-CI caveat (children get zero CI) does not apply; the PR's own checks are the gate, same as any normal PR.
- **Skip the sub-task machinery, keep the rigor.** No Step 0 slicing, no watcher, no 30-minute heartbeat loop, no merge-into-inscription-branch. Keep everything that makes a cast trustworthy: full diff review against the plan, local typecheck + the tests the plan names, contract-artifact discipline, Greptile triage, and **the demo — a direct-cast PR targets `main`, so it always gets one** (see "The demo": record the change working live, publish to hosting, attach to the PR, and present it in chat). Scale the walkthrough to the change — a backend fix's demo may be one screen plus the repro→resolution evidence — but never skip the recording.
- **You open the PR; the user reviews and merges.** Still the single merge to main, still theirs. Present the PR link, what it proves, and every judgement call as an assumption to check — exactly as the end condition below, minus the sub-task bookkeeping.

**When there is no inscription yet but you are *not* in direct mode** — the change warrants full ceremony — inscribe first, in this same run (next paragraph).

**No inscription yet, inscription-based mode? Inscribe first, in this same run — don't refuse and don't skip it.** (In direct mode, above, you skip this entirely.) `/cast` can be invoked directly on an approved divination, or on a change the user simply described. When there is no open inscription PR, begin by doing `/inscribe`'s job (read `~/.claude/skills/inscribe/SKILL.md` and follow it): author the contract deltas, open the inscription PR with base `main`, and keep it open — no Linear epic unless the user explicitly asked for one. Then continue with Step 0 below. Two adjustments when inscribing inside a cast:

- **The user is away, so the inscription's iterate-until-confirmed loop does not apply.** Author it, verify the gates are green, and record every judgement call you made in your status report as an assumption the user should check at final review — instead of blocking on their confirmation.
- **Scale the inscription to the change.** A change with genuine contract surface (new entities, commands, pages, agent tools) gets the full treatment. A change with almost none — dev tooling, scripts, docs, a single behavior tweak — gets a correspondingly small inscription; if it turns out there is *no* contract delta at all, say so plainly in the report and carry on with a plain feature branch as the base the children merge into. Everything downstream (children merge into that branch, one final user merge to main) is unchanged either way. Never invent contract surface to satisfy the ceremony.

**Prerequisite — inscription PR open.** Once inscribed (by `/inscribe` earlier or by you just now), the epic's inscription PR must exist and be open with base `main`. Ideally its CI is green; if it's red, **fix it in parallel — a red inscription does not block the cast.** Slicing and dispatching sub-tasks proceed concurrently with the fix: a red inscription is almost always an isolated gate miss (a stale allowlist, an unbuilt artifact) that children don't inherit into their implementation, and serializing the whole cast behind it idles the first wave for nothing. Open the fix as its own commit on the inscription branch right away and let its CI run alongside the first wave. The one thing a red big PR genuinely gates is **merging children** (step 5) — don't compound a red base — but even that is "fix immediately, in parallel," never "halt dispatch and review." If it's `DIRTY` against main, update the branch (merge `origin/main` into it, rebuild committed contract artifacts — never trust a text-merged generated JSON) before slicing. Its branch is `<inscription-branch>` everywhere below. **Never merge the inscription PR itself** — that final merge to main is the user's, after the demo.

**Prerequisite — opencode ready.** `opencode --version` runs and `opencode models` lists the `openai/` provider (auth check: `opencode auth list`). If unavailable, say so and implement the sub-tasks yourself this run instead of blocking.

## Autonomy

Run the whole loop autonomously — the user is away and will not answer mid-run. Never ask, never pause, never wait for input. Slicing, dispatching, reviewing, fixing, verifying, merging into the inscription branch, and closing tasks are all yours. When something would normally prompt a question, make the most reasonable call and record the assumption in your status report. Genuinely-user decisions (scope changes, inscription changes, an approach contradicting the epic's goal, human-only override labels, the final merge to main) get **flagged and routed around** — a clear note for later, never a blocked loop.

## Step 0 — Slice the casting into sub-tasks

Derive the implementation work from the inscription: the PR's diff plus the narrative's **deferred deltas** list (`~/.claude/artifacts/<id>/inscription.md`). **Author each sub-task as a local markdown file in `~/.claude/artifacts/<id>/tasks/<TASK-ID>.md`** — the files are the tracker, canonical for both content and status. Task ids are `<id>-1`, `<id>-2`, … (when a Linear epic exists and the user asked for Linear tracking, use the real PRD ids instead). Each file's first line is `Status: Ready | In progress | In review | Blocked | Done`, updated as the cast proceeds. Task bodies use plain terms per grimoire → Public wording — they get pasted verbatim into opencode prompts and quoted in PRs: reference "the epic PR" and "the contract spec", never "inscription", "cast", or "spell".

**No Linear issues.** Only when the user explicitly asks for Linear tracking, mirror the task files as sub-issues under the epic via GraphQL (`linear issue create/update --assignee` silently no-ops — set `assigneeId`/`parentId` via `issueCreate`/`issueUpdate`, raw `linear auth token` in the `Authorization` header, no `Bearer`; re-fetch to verify; renderer caveat in grimoire → Linear is opt-in) — the local files stay canonical either way.

Each sub-task carries:

- **Goal** — one sentence: what becomes true.
- **Contract deltas** — which inscription pieces this issue fulfills (link the stories/declarations), plus any deferred deltas it must itself produce: the artifact file and the precise entries/fields/values expected in its diff.
- **Validation criteria** — numbered; each pairs an outcome that is plainly true or false with the named, committed, re-runnable check that decides it (test file, benchmark assertion, gate expectation, artifact diff). No vibes — a reader runs the checks and says "achieved" or "not yet".
- **Deploy note** — required when the issue carries a migration or a flag: the big PR's merge is deploying, so state the rollout shape (expand-contract vs accepted transient errors, flag default).
- **Out of scope** — one line.
- **Dependencies** — which sibling(s) it builds on, if any.
- **Overlaps** — which siblings touch the same files or shared surfaces (whole-repo generated artifacts, `all-commands`, the same service) even with no logical dependency — unmarked overlap is how sibling PRs grind each other down in rebase conflicts.

Slicing rules:

- **The inscription decides outcomes; sub-tasks leave only implementation judgement.** Every decision about what the product becomes lives in the inscription or the task text, never in the implementer's discretion. Audit each sub-task: "where could the implementer choose between two different observable outcomes?" — decide it there. A decision that genuinely can't be made yet is a flag for the user, not a buried ambiguity.
- **Every sub-task must be independently implementable by a cold opencode session.** Full context in the file — file paths, commands, API surfaces, known gotchas, links to the inscription PR and relevant stories. opencode cannot see this conversation and cannot ask questions. Don't restate what repo `CLAUDE.md`/`AGENTS.md` already documents.
- **Slice vertical.** Each sub-task delivers a user-visible increment end-to-end (data + API + UI for a subset of functionality), never backend-now-UI-later. Standalone non-vertical tasks only for: deliberate no-UI contract/SDK work, cleanup/migration/tooling, or a genuinely shared foundation — and prefer folding a foundation into the first slice that uses it. A UI-visible sub-task's validation includes a user-facing check (play-function/VRT assertion or screenshot), not just backend tests.
- **Fewest reviewable PRs.** Plan the minimum PR count where each stays one coherent concern.

## Role boundaries

- **Every public surface you write — PR titles and bodies, GitHub review comments, commit messages, Linear text — uses plain terms** per grimoire → Public wording: "the epic PR", "the contract spec", "implementation", never "inscription"/"cast"/"spell". The cycle vocabulary stays in this file and in chat with the user.

- **You originate implementation by dispatching opencode — never by hand-writing the first draft.** A ready sub-task with no PR and no running session is work to dispatch. Reviewing, fixing, finishing, and merging into the inscription branch are yours.
- **Every finding is yours to resolve — two ways, your call which is faster:** (a) resume that sub-task's opencode session with the specific correction (best for real implementation rework the session has context for), or (b) fix it yourself on the PR branch (best for small/mechanical fixes). Either way, verify the result yourself (typecheck + relevant tests) and document it in a PR comment. A finding is never left as an unanswered request.
- **The inscription is the spec.** Implementation PRs must conform to it. A sub-task that carries deferred deltas must produce exactly those artifact diffs — verify against the task file. An *unexpected* contract delta (an unplanned Breaking/Notable label, an artifact change no task called for) is a finding: either the PR is wrong (fix it) or the inscription missed something (flag for the user). Breaking overrides are human-only — flag, continue with everything else.
- Don't invent scope: only this cast's sub-tasks, nothing else, however green it looks.

## CI reality of casting into a branch

`pr.yml` fires only on PRs whose base is `main`. Consequences you build the whole loop around:

- **Child PRs (base = `<inscription-branch>`) get ZERO CI.** Their `CLEAN` status is *unverified*, not green. The merge gate for every child is your local verification: full diff review, package typechecks, the tests its validation criteria name, contract artifact diffs matching the issue.
- **The big PR is the real gate — for merges, not for dispatch.** Every merge into the inscription branch re-triggers the inscription PR's own CI. After **every** child merge, watch that run to a terminal state; a red big PR blocks further *merges* (don't stack merges on a red base) — diagnose and fix immediately, in parallel with continued dispatch and review of other children. A red big PR never halts slicing, dispatching, or reviewing. Impact labels recompute there too — check them against the inscription's expectations.
- A red **non-required** workflow on the big PR (e.g. VRT "Capture stories") never blocks — note it and move on; "runner lost communication" or a run with no failed step is an infra flake → `gh run rerun --failed`.

## Dispatching opencode

opencode runs as headless `opencode run` in an isolated git worktree per sub-task. There is no dispatch helper script — you create the worktree and capture the session yourself. Dispatch with the **balanced tier: `-m openai/gpt-5.6-terra`; never the frontier tier (`openai/gpt-5.6-sol`), never an upward override** — if a sub-task seems too hard for balanced, the fix is a sharper prompt, not a bigger model.

1. Build the self-contained implementer prompt (template below) — paste the full task file verbatim; opencode sees nothing else. Write it to a scratchpad file.
2. Create the worktree and branch — the base is **always** the inscription branch (or `oc/<DEP-ID>` to stack on an unmerged dependency — rare; prefer waiting for the merge and dispatching off the fresh tip):
   ```bash
   git -C <main-checkout> worktree add .claude/worktrees/oc-<TASK-ID> -b oc/<TASK-ID> origin/<inscription-branch>
   ```
   Seed what a fresh worktree needs per the repo's `AGENTS.md` (env files, dependency install) before dispatching — opencode starts cold.
3. Launch as a **background** Bash task (`run_in_background: true`), logging JSONL:
   ```bash
   opencode run --dir <worktree> -m openai/gpt-5.6-terra --auto --format json \
     "$(cat <prompt-file>)" > <scratchpad>/oc-<TASK-ID>.jsonl 2>&1
   ```
4. On completion, extract the session id from the log and **record `sessionID` + worktree per issue** — the session id is how you send feedback (`opencode run -s <id>`), the worktree how you inspect locally:
   ```bash
   jq -r '.sessionID // empty' <scratchpad>/oc-<TASK-ID>.jsonl | head -1
   ```
5. **Session ended with no PR but a dirty worktree? Recover, don't re-dispatch.** First `git fetch && git rev-parse origin/oc/<TASK-ID>` — origin may be AHEAD of the local branch (a partial push), and committing blindly on the local state would wipe it. Reconcile against origin, commit + push opencode's edits yourself, open the PR yourself. Re-dispatch only when the log shows the implementation itself went wrong.

## Scheduling: waves onto a moving tip

Children merge into the inscription branch as they're accepted, so the branch tip advances throughout the cast:

- **Dispatch in small waves off the current tip.** A child dispatched before its overlap-partner merged will need a rebase onto the new tip — sub-tasks the plan marks as overlapping (same files, same service, shared generated artifacts) go in one wave-slot serially, never racing. **Artifact-touching sub-tasks land serially, one per quiet window.**
- **A dependent sub-task waits for its dependency to merge** into the inscription branch, then dispatches off the tip — stacking on `oc/<DEP-ID>` is the fallback when waiting would idle the whole cast, and its base must be a PR you've already reviewed.
- **Rebasing children onto the advanced tip is yours** — `git rebase --onto origin/<inscription-branch> <old-base-tip> oc/<TASK-ID>`, `git push --force-with-lease`, rebuild any committed contract artifacts. When a rebase becomes archaeology (conflicts piling), don't grind: **re-dispatch fresh against the current tip with every review decision baked into the prompt** — routinely cheaper than surgical rebasing.
- **Keep the inscription branch current with main between waves.** Being behind main is mergeable (only real conflicts, `DIRTY`, block), but don't let drift compound: when main moves significantly or the big PR goes `DIRTY`, merge `origin/main` into the inscription branch between waves (no open children mid-flight), rebuild artifacts, wait for the big PR's CI.

## Dispatch throttle

There is no local usage meter for opencode. Throttle by policy instead:

- **Cap ~2 sub-task sessions in flight**; go to ~3 only after several waves have landed cleanly. Small steady waves beat a fan-out.
- New sessions and resumes (`opencode run -s <id>`) consume provider quota; your own reviews/fixes/merges don't — shift mechanical work to yourself when dispatch feels expensive.
- If a dispatch log shows provider throttling (HTTP 429, quota or rate-limit errors), **PAUSE** dispatching, report it as a blocker, and resume only after a one-session probe succeeds.
- Each `step_finish` JSONL event carries a `tokens` object — sum them per session when the user asks what a cast consumed.

## Feeding feedback back to opencode

```bash
opencode run --dir <worktree> --auto -s <session-id> \
  "Address this PR review on branch oc/<TASK-ID>: <exact findings, one per line>. Re-run the package typecheck + tests you touched, then amend the branch and push."
```

After opencode pushes, **re-review the new commits from the diff** — never take the reply's word for it.

**All rebases are yours.** Never resume opencode to rebase — do all rebases and cross-PR conflict resolution yourself: a session asked to rebase burns quota on archaeology and races your view of the tip. Before committing a manual fix in an opencode worktree, run `git fetch && git reset --hard origin/oc/<TASK-ID>` first so you build on the real pushed PR — the session may have pushed after your last look at the worktree.

### Implementer prompt template

Fill every `<…>` and paste the task file verbatim — opencode has no other context.

```
You are implementing ONE task end-to-end in the Membrane `platform` monorepo. You are working in a fresh git worktree on branch `oc/<TASK-ID>`, based on <INSCRIPTION-BRANCH>.

## Task — <TASK-ID>: <title>
<Paste the full task file: Goal + Contract deltas + Validation criteria + Out of scope + all context — file paths, commands, gotchas, links.>

## How to work
- FIRST read `AGENTS.md` at the repo root and follow it exactly — tooling, worktree rules, testing, finalizing, and the per-area guides it links. It answers most environment questions (fresh-worktree setup, formatters, test runners); trust it over your instincts, and quote a command's verbatim error before concluding the environment is broken.
- The product contracts for this epic are already committed on your base branch — your job is to make the product fulfill them. Follow "Making Changes" in each affected `contracts/<name>.md`, rebuild touched artifacts (`bun run contracts:build:<name>`), and commit them with the change. If the task specifies exact contract deltas, your artifact diff must match them exactly.
- The DoD is the Validation criteria: the exact committed checks they name must exist and pass.
- Stay strictly inside this task's scope and Out-of-scope boundary. Do NOT merge anything.

## Verification rules (each exists because its violation shipped a bug)
- If your change removes or renames an export, entity, or API surface: grep the WHOLE repo for consumers, then `bun run build:all` and typecheck every affected package — a single-package typecheck passes against stale built dists and lies.
- DELETE a test file only if its subject IS the removed behavior/entity. A surviving-entity test that merely references the removed thing gets those references edited out — never delete the file.
- Never disable a test (`.skip`) — lint fails CI on it. Delete (per the rule above) or fix.
- A failing suite is "pre-existing" only after you run the SAME suite on your base branch and compare both results. Never claim it without the baseline.
- Before finishing: `cd` into each changed package and run `bun run typecheck` plus the relevant tests (runners per AGENTS.md → Testing), then `bun run fix`. Do not finish red.

## Deliverable
- Commit with a clear message ending with the trailer:
  `Co-Authored-By: opencode <noreply@opencode.ai>`
- Push branch `oc/<TASK-ID>`.
- Open a PR: `gh pr create --base <INSCRIPTION-BRANCH> --head oc/<TASK-ID>`. Title MUST start with `<TASK-ID>: ` so the PR maps back to its task (and so Linear links it when real issue ids are in use). Body follows the repo format: `## Summary`, `## Problem Reproduction`, `## Solution`, `## Review Context` — paste your passing typecheck/test output under Review Context. Note: PRs into this base run no CI; your pasted local results ARE the review evidence.
- Do NOT capture or attach screenshots — this PR is nested (its base is not `main`), and nested PRs skip visuals; the epic's demo carries the visual proof. For a UI-visible change, your review evidence is the play-function/VRT assertions your validation criteria name plus your pasted test output.
- Print the PR URL as your final message.
```

## Watch + heartbeat

Two things wake you: each opencode background task on completion, and a bash watcher on PR-state changes. A 30-minute loop catches what both miss.

1. **First pass:** run one full pass (below) immediately.
2. **Arm the watcher** over the full child-id set from Sync — every not-yet-Done child, never a subset. No helper script exists — run an inline poller as a background Bash task: every ~60s snapshot each child PR and the big PR (`gh pr view <N> --json state,commits,statusCheckRollup,reviews,body`), hash the combined output, and exit when the hash changes (new/closed PRs, commits, checks, reviews, PR-body edits — how Greptile reports). Bound it: exit after 6h of quiet; on repeated `gh` API failures, check `gh auth status` before re-arming.
3. **On wake:** run a pass, then re-derive the child list from the `tasks/` directory and re-arm the watcher from that fresh set — after the pass, never from memory.
4. **Heartbeat — mandatory:** arm `/loop 30m /cast <epic-or-topic>` in the first pass; verify it exists on every pass and re-arm if missing; never cancel it while the cast is open. On a loop-invoked pass, run the stuck-detection checklist instead of full work: watcher alive? opencode sessions *progressing* (dispatch-log mtime — alive-but-stale ≥ 20 min = stuck: read the tail, then resume with a nudge (`-s <id>`), re-dispatch, or take over)? every believed-in-flight sub-task has a live background task or a recorded `sessionID`? armed id set matches a fresh `tasks/` read? throttling errors in dispatch logs? big PR CI green? Then one light pass. Healthy and quiet → stay silent, keep the loop.

## Each pass

1. **Sync.** Re-read the **complete** child list from `~/.claude/artifacts/<id>/tasks/` — the single source of truth, never a remembered list. Enumerate every task file in every status and account for the total count. Non-active children (a task file marked Canceled/Duplicate in its Status line) count as resolved, explicitly. For each active child, find its PR: `gh pr list --search "<TASK-ID>"` (branches are `oc/<TASK-ID>`). (When mirroring to Linear on explicit request, also reconcile issue states there — `linear issue view <ID> --json`, read `state.name`, never `grep -i state`; the local files remain canonical.)

2. **Dispatch.** Apply the throttle policy (Dispatch throttle) → this pass's concurrency cap. Then for each active child with no PR and no running session, apply the wave rules (Scheduling): non-overlapping ready issues dispatch off the current inscription tip; a child whose dependency or overlap-partner hasn't merged yet is blocked — report it as blocked-on-`<DEP-ID>`. Record `sessionID` + worktree from each completed dispatch log.

3. **Review and fix.** For each open child PR with unreviewed commits: read the full diff (`gh pr diff`; checkout when you need to run things) and judge it against the sub-task's validation criteria, its contract deltas (artifact diffs match the task text; no unplanned contract changes), correctness, and the repo PR-body format. **Child PRs are nested (base = the inscription branch, not `main`) so they skip PR visuals** — the epic demo on the big PR carries the visual proof; a child's review evidence is your local verification, not screenshots. **Run the verification yourself** — children get no CI, so your local typecheck + tests are the only gate. Resolve every finding now — resume opencode or fix it yourself — verify, and post one GitHub review documenting what was found and which commit fixed it.

4. **Verify follow-ups.** Re-check open threads against new commits — confirm fixes in the diff, never from a reply. If Greptile reviewed the child PR, triage every P1/P2: fix or answer why not (body block + inline comments per repo `CLAUDE.md` → AI PR Review). The big PR gets fresh Greptile passes as merges land — triage there continuously too.

5. **Merge into the inscription branch.** When a child PR is fully reviewed (your findings resolved, local verification green, Greptile triaged, contract deltas verified): `gh pr merge <N> --squash` (its base is the inscription branch, so this never touches main). Then **watch the big PR's CI run to a terminal state** — that run is the real gate; red blocks further merges until fixed. Never `--delete-branch` while any sibling still stacks on the branch; never enable GitHub auto-merge; **never merge the inscription PR**.

6. **Close out.** Right after each child merge: flip the task file's Status to Done (as you go, never batched; mirror to Linear only when tracking there on explicit request), remove its worktree (`git -C <main-checkout> worktree remove .claude/worktrees/oc-<TASK-ID>`, `--force` if needed), and rebase any in-flight children onto the new tip (Scheduling) so they stay current.

7. **Report.** Post a short status only when something changed — dispatch, new PR, review, fix, merge, or a new blocker/assumption/throttle event. A no-change pass stays silent.

## The demo — proof of manifestation

**The standing rule: every PR whose base is `main` ships with a recorded demo — the big PR of an inscription-based cast and every direct-cast PR alike, no exceptions and no waiting to be asked. Nested PRs (base = another PR's branch) skip visuals entirely.** The demo is both *output* (presented in chat with the final report) and *attached to the PR* (published to hosting, linked in the PR body with key frames embedded).

When every child is merged and the big PR is green, prove the spell in the **real product** — as real as possible: full dev stack (`bun run dev` in the epic's worktree on the inscription branch, then `bun run dev:wait` for a ready-or-failed signal), seeded auth, and the dev-stack helpers in `internal-dev-doc/browser-automation.md` (`dev:token` to inspect workspace state instead of reading Postgres, `seed:demo-job` for a launchable job, `?noAutoLogin` to reach the login screen).

**Never type a port into a demo step.** Other worktrees are usually running their own stacks, and `bun run dev` auto-discovers ports, so `localhost:9000` is probably a different branch's app — which does not error, it just quietly demos the wrong code. Derive every URL from `bun run dev:url [path]`, which resolves this checkout's stack and refuses to guess when none is running. Confirm you are on the right one before the first capture: the port `dev:wait` reports and the port you drive must be the same, and the branch under test must be what that stack is serving.

1. **Walk through every new flow end-to-end as a user** — not stories, the running app: create the real entities, click the real buttons, watch the real jobs run. **Validating and capturing are one pass**: drive with a Chrome MCP and pass `filePath` to `take_screenshot` so each verified step writes its own PNG (grimoire → screenshot mechanics). Re-driving the whole flow with a second tool just to produce files is the failure mode this replaces.
2. **Validate against the inscription.** Each flow section of the inscription narrative gets checked live: does the product do what the inscription promised? Exercise the validation criteria's user-facing halves for real.
3. **Build the demo HTML** (grimoire → artifact storage + HTML mechanics; this page is published to the team — all visible text follows grimoire → Public wording), `demo.html` in the epic's artifact dir:
   - **The walkthrough** — product-order sections over the live captures: what the user now sees and does.
   - **How it was built** — per sub-task: one-paragraph what/how, PR link, anything notable about the implementation.
   - **The discrepancy report** — the contract spec compared section-by-section against what actually shipped. Every divergence listed and classified: *implementation constraint* (with the constraint), *contract gap discovered during implementation* (with the follow-up contract change it implies), *intentional refinement* (with who decided), or *defect* — a defect found here is fixed before presenting, not reported. No silent divergences: if the demo can't show something the contract spec promised, that line item says so explicitly.
4. **Publish it to the team, as one link.** `bun run demo:publish <demo.html> --pr <N>` uploads to the VRT bucket and prints a `https://vrt.membrane-dev.com/platform/demos/pr-<N>/index.html` URL. That host is behind the team's Cloudflare Access SSO, so the same link works everywhere: paste it in chat for the user, put it in the big PR body's Review Context, and attach it to the Linear epic when one exists. Re-running with the same `--pr` overwrites in place, so the link never goes stale. Mechanics and credentials: repo README → "Publishing a demo".

   Three things that link does not excuse:

   - **Refresh the big PR's title and body to match its final contents.** They were authored when the PR held only the contract spec; now it holds the whole change. The title must name the product change itself (e.g. "PRD-1234: Deliverable views" — never "Contract spec for …" or any other snapshot of an earlier state), and the Summary/Solution must describe everything in the final diff. The user reviews and merges this PR as the whole change, and it becomes the permanent record of it.
   - **Say what the demo proves.** Lead the Review Context with a sentence of outcome, not just a URL. A reviewer who never clicks should still know what happened.
   - **Embed the few frames that carry the story** with `bun linear-upload <png>` → `![caption](URL)`, so the PR is reviewable at a glance. The published page is the full walkthrough; inline images are the summary.

   Do **not** rely on a Claude Artifact for team review — it is private until the user shares it, and an uploaded `.html` serves as `content-disposition: attachment`, which downloads instead of rendering. Publish to the VRT host and the problem disappears.

## End condition

Against a **fresh** read of the `tasks/` directory, never a remembered list: every child terminal (Done, or Canceled/Duplicate), no open child PR, no opencode session running, big PR green, demo published, big PR title and body refreshed to describe the full shipped change (see "The demo"). Then: remove leftover `oc/*` worktrees, kill the watcher, cancel the loop, and present the final report to the user — the big PR link, the demo link, the discrepancy summary, and anything flagged for their judgement. **The user reviews and performs the final merge to main** (or explicitly asks you to after their review). When a Linear epic exists, it goes Done when the big PR merges — not before.
