# Calibration

The calibration procedure, reached from [Calibration](SKILL.md#calibration) in SKILL.md.

An assertion observed only green is **uncalibrated** (`~/.claude/shared/testing.md`, False green); so is one whose test stops at an earlier assertion. This procedure supplies the post-green regression evidence for such assertions, and for a masking helper or fixture found in review. The preparation report names the finite plan in `ticket.md`. A known-bad revision or an already observed faithful mutation supplies the same evidence while the protected state is unchanged.

`Non-goals` constrains final behavior, not temporary mutation paths. A non-goal that says "never touch path X" needs a different mutation plan, resolved before the calibrate child starts.

## First calibration

After the lock and test command are green, record `calibration_sha` and start a test writer in **calibrate** mode ([brief](test-writer.md#calibrate)) with the planned temporary production paths. Tests and fixtures stay unchanged; the child returns the branch to `calibration_sha` before reporting, including on failure. It saves each mutation as a patch under `calibration-<n>/` ([run-directory.md](run-directory.md)); copy each patch path into its plan row in `ticket.md`.

Inspect the saved patches and command logs. Each named regression needs red on its protected assertion and valid green evidence for the restored state. Require unchanged HEAD, `git diff --exit-code <calibration_sha>`, and a clean worktree. Complete the agreed regression list.

## Replay

When `git diff --name-only <calibration_sha> HEAD` lists a path outside the lock and every plan row has a patch, replay the patches instead of dispatching a child: record the new `calibration_sha`, then for each row apply its patch (`git apply <patch>`), run its focused command, and restore the paths (`git restore --source=<calibration_sha> --staged --worktree -- <paths>`), saving the command, its output, and its exit status under `replay-<m>/`. Require red on the protected assertion, then `git diff --exit-code <calibration_sha>` and a clean worktree, before the next row. A replay dispatches no child and is not a turn.

A patch that does not apply, or a run that stays green, ends the replay for that row: restore the paths, verify the state, and send the row with its saved log to a fresh calibrate child (the **Calibration** row of [recovery.md](recovery.md#responding-to-a-failure)), whose verdict decides between **calibrated** and **suspect test**. Rows that replayed red keep their evidence. A re-locked owner test or fixture, or a changed plan row, needs a calibrate child, not a replay.

## Verdicts

- **Calibrated:** record the commands, results, and protected state in Verdicts. Reuse this evidence while the lock, the plan, and every path outside the lock are unchanged since its `calibration_sha`; a changed path outside the lock takes the [replay](#replay).
- **Suspect test:** a faithful regression stayed green. Record the counterexample and take the suspect-test route under [Entering mid-chain](SKILL.md#entering-mid-chain) within the current batch.
- **Blocked:** no faithful regression or environment can be established, or restoration cannot be verified. Diagnose and report the limit; a skipped or setup-failing mutation is not calibrated.
