# Calibration

The calibration procedure, reached from [Calibration](SKILL.md#calibration) in SKILL.md.

An assertion is **uncalibrated** until an observed regression makes it red for its stated reason. A test that is green before production exists, or stops at an earlier assertion, provides no such evidence for the protected assertion.

Use this for uncalibrated negative or aggregate assertions, or a masking helper or fixture found in review. The preparation report names the finite plan in `ticket.md`: criterion, owner test, protected assertion, smallest regression, and mutation paths. A known-bad revision or an already observed faithful mutation supplies the same evidence while the protected state is unchanged.

`Non-goals` constrains final behavior, not temporary mutation paths. A non-goal that says "never touch path X" needs a different mutation plan, resolved before the calibrate child starts.

After the lock and test command are green, record `calibration_sha` and start a test writer in **calibrate** mode ([brief](test-writer.md#calibrate)) with the planned temporary production paths. Tests and fixtures stay unchanged; the child returns the branch to `calibration_sha` before reporting, including on failure.

Inspect the saved mutation diffs and command logs. Each named regression needs red on its protected assertion and valid green evidence for the restored state. Require unchanged HEAD, `git diff --exit-code <calibration_sha>`, and a clean worktree. Complete the agreed regression list.

- **Calibrated:** record the commands, results, and protected state in Verdicts. Reuse this evidence until that code, its owner tests, fixtures, or regression plan changes.
- **Suspect test:** a faithful regression stayed green. Record the counterexample and take the suspect-test route under [Entering mid-chain](SKILL.md#entering-mid-chain) within the current batch.
- **Blocked:** no faithful regression or environment can be established, or restoration cannot be verified. Diagnose and report the limit; a skipped or setup-failing mutation is not calibrated.
