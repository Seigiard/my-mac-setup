---
title: "A validate-cmd segment that matches no files exits zero, so the gate passes on a check that covered nothing"
short_description: "A validate-cmd segment that matches no files exits zero, so the gate passes on a check that covered nothing"
type: "bug"
category: "se-pipeline"
tags: ["se-pipeline","bug"]
date: "2026-08-14"
status: "done"
priority: "low"
closed: "2026-08-15"
---

# A gate segment can pass while verifying nothing

## Why this exists

The work gate takes the validate-cmd's exit code as ground truth (KTD3). A linter or test runner pointed at a path outside its configured scope finds zero files, has nothing to complain about, and exits zero. The gate reads a pass.

Observed twice on the `platform` plans run through the pipeline. The plan's contract ran `oxlint` over `scripts/`, a directory outside the tool's configuration, and the tool reported that it processed zero files and exited zero. The validate output from `run-1786718288581` carries the same shape of message:

```
$ sqlite3 ~/.claude/.smithers/smithers.db \
  "SELECT reasons FROM gate_verdict WHERE run_id='run-1786718288581' AND node_id='gate-work-extra';"
validate-cmd exited with code 1; validate-cmd output tail: atterns.
No files found matching the given patterns.
…
```

That particular run still went red, because a different segment of the same command failed a real test. Had it not, the run would have gone green with one of its two declared gates having inspected nothing.

The failure is silent by construction. Nothing distinguishes "ran and found no problems" from "ran and had nothing to run on" in an exit code, and the pipeline reads nothing but the exit code. The plan declared a lint gate; the operator believes a lint gate ran; the run's green verdict asserts it.

This is a different defect from `docs/issues/2026-08-14-010-validate-cmd-filter-is-unsound-in-both-directions.md`. That one is about which commands the derivation keeps. This one is about a kept, valid, correctly-derived command whose coverage is empty.

## Scope

- `home/private_dot_claude/dot_smithers/workflows/se-pipeline.tsx` — the work gate's validate execution, where output is captured and currently used only for the failure tail.
- `home/private_dot_claude/dot_smithers/workflows/lib/gates.ts` — `workGate`, which classifies on exit code alone.

## Open decisions

- **Whether a vacuous pass is detectable in general.** Every tool phrases empty coverage differently ("No files found matching the given patterns", "0 files", "no tests found"), and a phrase list will always trail the next tool. It fails toward silence, which is the current state anyway.
- **Whether the gate should require positive evidence instead.** A command that must report what it checked — file counts, test counts — turns the question from "did it fail?" into "did it cover anything?". That constrains what a validate-cmd may be, and pushes work onto the plan author.
- **Whether this belongs in the plan contract rather than the gate.** If a plan declares its gates explicitly (`docs/issues/2026-08-14-014-plan-format-contract.md`), it could also declare what each gate is expected to cover, and the mismatch becomes checkable.
- **Whether to surface it as advisory rather than blocking.** Recording "this segment reported zero files" in the run notes costs nothing and does not risk failing a legitimate run, but it is only useful to an operator who reads notes.

## Resolution

Advisory, not blocking. The work gate keeps reading the validate-cmd's exit code as ground truth (KTD3) and gains a second, weaker signal that costs nothing when it is wrong.

- `emptyCoverageSignals` / `emptyCoverageReason` / `emptyCoverageNotes` in `home/private_dot_claude/dot_smithers/workflows/lib/gates.ts` — a pure classifier over the captured validate output that returns the matched **line**, not a boolean, so the reason quotes the tool's own words.
- `workGate` settles its state first, then appends the advisory when the command exited **zero** and the output carries a signal. A green gate stays green; a gate already red for another reason stays red. A non-zero exit produces nothing: that run already fails and already gets the output tail, so the signal would only be noise.
- `se-pipeline.tsx` lifts the advisory out of the persisted work verdict into `summary.notes` (`work: validate-cmd may have covered nothing (advisory) — …`), so `se show <runId>` names it without a re-read of the run log. No new persisted field: the advisory rides in the `gate_verdict.reasons` column that already exists, so a row written before this change simply carries no such reason and a resumed run is unaffected.
- Runbook: a `validate-cmd` bullet in `docs/se-pipeline.md` names the failure mode, the advisory, and its limits.

### The four open decisions

**Is a vacuous pass detectable in general? No — and the list is honest about it.** Each phrase was verified by running the tool against a path matching nothing on 2026-08-15: oxfmt `--no-error-on-unmatched-pattern` ("No files found matching the given patterns.", exit 0), oxlint ≤1.50 ("Finished in 4ms on 0 files with 96 rules", exit 0) and ≥1.60 ("No files found to lint.", exit 1), vitest 4.1.10 ("No test files found, exiting with code 0" under `--passWithNoTests`), ruff 0.16.3 ("warning: No Python files found under the given path(s)", exit 0), pytest 9.1.1 ("collected 0 items" / "no tests ran in", exit 5), bun 1.3.14, jest 30.4.1, tsc 6.0.3 (TS18003), eslint 10.8.1, prettier 3.9.6, biome. **Accepted gap:** a tool that exits 0 and prints nothing is undetectable — `eslint --no-error-on-unmatched-pattern 'nope/**/*.ts'` exits 0 with zero bytes of output. The list fails toward silence, which is the behaviour without it.

**Should the gate require positive evidence instead? No.** Demanding that a validate-cmd report file or test counts constrains what a validate-cmd may be — every tool would have to have a machine-readable count, and plans whose contract is a plain `make test` would stop being expressible. It also pushes the work onto the plan author, who is the person least able to know what a tool prints in a bare worktree. The gate stays able to accept any command the operator trusts.

**Does this belong in the plan contract instead? Not as a dependency.** `docs/issues/2026-08-14-014-plan-format-contract.md` is an open design question with no decision; a plan that declared expected coverage per gate would be a stronger check, but this fix must not wait on a format that does not exist. The advisory is independent of it and stays useful if 014 ever lands.

**Advisory rather than blocking? Yes.** Turning a matched phrase into a red gate buys a whole extra work leg on a false positive — the same trade-off already recorded for `mainCheckoutEscapeReason`. The advisory is only useful to an operator who reads notes, which is why it is lifted into `summary.notes` rather than left in the run log.
