---
title: A validate-cmd segment that matches no files exits zero, so the gate passes on a check that covered nothing
type: bug
date: 2026-08-14
status: open
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
