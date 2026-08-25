# The smithers harness for `/se-doc-review`

Not a command. `se-doc-review` launches a smithers workflow that runs external agent legs (claude + opencode) in parallel. Its skill states only what differs: the workflow file, input JSON, scan range, and output fields.

## Launching

Launch from `~/.claude/.smithers`, never from the target repo: smithers drops its runtime state in the working directory, and that directory's `.gitignore` covers it. The pinned `smithers-orchestrator` version is in `~/.claude/.smithers/package.json`.

Every launch goes into ONE background Bash task (`run_in_background: true`) so the session stays free.

Add `"smoke":true` to the input JSON for a cheap wiring test — no real review, no apply.

## Pre-external secret gate

Before anything is staged or copied, the harness runs `gitleaks` over the material the external legs would see and **refuses the run** on a finding, or on a scanner it cannot run. A refusal fails the `stage` task with a redacted reason, leaves no `/tmp` copy, and sends nothing to claude or opencode.

Fix it by redacting the secret and re-running. To send anyway, prefix the launch command with `SE_SKIP_SECRET_SCAN=1`.

Each skill states the range it scans. The gate bounds only that range: a secret already present outside it is not scanned.

## Staging and opencode's read permission

Staging (the frozen snapshot or document copy, plus the plugin-skill bundle) lives under `/tmp/<workflow-name>/run-<ts>/`. opencode reads it through the `permission.external_directory` allow in `~/.config/opencode/opencode.json`. **If an opencode leg starts failing with rejected reads, check that config before touching the workflow.**

`/tmp/<workflow-name>/run-*` directories are ephemeral tmp — leave them. Nothing inside the repo ever needs cleanup; the harness removes its own git worktree. If a crashed run leaves a worktree behind, `git -C <repo> worktree prune` from the main checkout clears the metadata.

## Error boundaries — a failed leg is not a failed run

Every external leg is wrapped in an error boundary. A leg that fails leaves the run alive with that leg's status `failed` and the surviving leg's output still collected. Use what exists, name the failure in the Coverage section of your synthesis, and diagnose afterwards:

```bash
cd ~/.claude/.smithers && ./node_modules/.bin/smithers logs <runId>   # or: smithers chat <runId>
```

Actual claude spend appears as `total_cost_usd` lines in the background task output. A `maxBudgetUsd` in a workflow is a runaway circuit breaker, not a cost target.

## Waiting for the harness

Cap the wait at **~65 min**, computed as `maxAttempts × per-leg timeout + ~15 min` of smithers reap lag on a timed-out attempt. The current per-leg timeouts and attempt counts live in `~/.claude/.smithers/workflows/lib/agents.ts` and the runbook `~/Projects/my-mac-setup/docs/se-pipeline.md` — read them there rather than trusting a number written into a skill.

Past the cap, treat the harness as hung and its reports as failed.

## Recursion guard

Each skill embeds a marker string in every consult prompt it sends. An agent whose own prompt contains that marker **is** one of the external consults: it executes only the work the prompt describes and returns its report. It never launches the harness or another consult.
