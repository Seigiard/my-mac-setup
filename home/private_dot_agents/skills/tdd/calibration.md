# Calibration

**Uncalibrated** (`~/.claude/shared/testing.md`, False green) also covers an assertion its test never reaches. The preparation report names the finite plan in `ticket.md`. A known-bad revision or an already observed faithful mutation supplies the same evidence while the protected state is unchanged.

`Non-goals` constrains final behavior, not temporary mutation paths. A non-goal that says "never touch path X" needs a different mutation plan, resolved before the calibrate child starts.

## First calibration

After the lock and test command are green, record `calibration_sha` and start a test writer in **calibrate** mode ([brief](test-writer.md#calibrate)) with the planned temporary production paths. Copy each saved patch path into its plan row in `ticket.md`.

Inspect the saved patches and command logs. Each named regression needs red on its protected assertion and valid green evidence for the restored state. Require unchanged HEAD, `git diff --exit-code <calibration_sha>`, and a clean worktree. Done when every row has red and restored-green evidence.

## Replay

When `git diff --name-only <calibration_sha> HEAD` lists a path and none of them is locked, and every plan row is unchanged and carries a patch, replay the patches instead of dispatching a child: record the new `calibration_sha`, then for each row apply its patch from the checkout root (`git apply <patch>`), run its focused command, and restore the paths (`git restore --source=<calibration_sha> --staged --worktree -- <paths>`), saving the command, its output, and its exit status in `replay-<m>/<regression>.log`. Require red on the protected assertion, then `git diff --exit-code <calibration_sha>` and a clean worktree, before the next row. A mutation that touched generated or ignored state needs that state restored and fresh green evidence for the test command; otherwise the step 5 green on `calibration_sha` stays valid.

A patch that does not apply, or a run that stays green, ends the replay for that row: it takes the **Calibration** row of [recovery.md](recovery.md#responding-to-a-failure). Rows that replayed red keep their evidence; on **calibrated**, copy the new patch paths into their rows.

Done when every row has red evidence in `replay-<m>/` or went to a calibrate child, and the worktree is clean at `calibration_sha`. Record a complete replay in Verdicts as `replay-<m>: calibrated; state <sha>; logs replay-<m>/`.

## Verdicts

- **Calibrated:** record the commands, results, and protected state in Verdicts. Reuse this evidence while the lock, the plan, and every path outside the lock are unchanged since its `calibration_sha`.
- **Suspect test:** a faithful regression stayed green. Record the counterexample and take the suspect-test route under [Entering mid-chain](SKILL.md#entering-mid-chain) within the current batch.
- **Blocked:** no faithful regression or environment can be established, or restoration cannot be verified. Diagnose and report the limit; a skipped or setup-failing mutation is not calibrated.
