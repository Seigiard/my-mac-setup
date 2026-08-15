---
title: The validate-command filter judges commands by substring, so it drops real gates and admits mutating ones
type: bug
date: 2026-08-14
status: done
closed: 2026-08-15
---

# The validate-command filter is unsound in both directions

## Why this exists

`isRunnableVerification` (`home/private_dot_claude/dot_smithers/workflows/lib/plan.ts:31`) decides which commands from a plan's Verification Contract become the work gate. It uses two heuristics: a keep set matched against whole tokens (`test`, `lint`, `check`, `tsc`, …) and a forbid list matched as raw substrings (`fix`, `format`, `serve`, `e2e`, …).

Both directions are wrong in ways that are silent. Every line below is real output from the current code:

```
$ cd home/private_dot_claude/dot_smithers && bun -e '
const { extractValidateCmd } = await import("./workflows/lib/plan.ts");
const f = (cmd) => extractValidateCmd("## Verification Contract\n\n```bash\n" + cmd + "\n```\n");
for (const cmd of [...]) console.log(cmd, "->", f(cmd));'

oxlint --deny-warnings src/a.ts             -> null
oxlint --deny-warnings src/a.test.ts        -> "(oxlint --deny-warnings src/a.test.ts)"
bun test tests/fixtures/plan.test.ts        -> null
npm run test:unit -- --grep fixture         -> null
oxfmt --write src/a.test.ts                 -> "(oxfmt --write src/a.test.ts)"
oxfmt --write --check tests                 -> "(oxfmt --write --check tests)"
biome check --write src/a.test.ts           -> "(biome check --write src/a.test.ts)"
bun test && oxfmt --write src               -> "(bun test && oxfmt --write src)"
```

**A real gate is dropped when its runner's name is not a keep token.** `oxlint` tokenizes as one word, so it does not match `lint`. The command survives only when some other part of the line happens to contain a keep token — in the observed case, the filename `pre-push.test.ts`. The lint gate of that run was kept by accident, and renaming that test file would silently drop it. The run would still go green, verifying less than the plan demanded, with nothing in the output saying so.

**A real gate is also dropped by substring collision on the forbid side.** `fix` is matched as a substring, so any path containing `fixtures` or `fixture` forbids the whole command. This repository keeps its own tests under `tests/fixtures/`, so a plan that scopes a gate to a fixture path loses it.

**A mutating command is admitted whenever the line carries a keep token.** `--write` is not on the forbid list at all; the list guards against `fix` and `format` by name. So `oxfmt --write src/a.test.ts` is accepted (keep token from the filename), and `oxfmt --write --check tests` is accepted twice over (`check` is itself a keep token). A compound line is judged as one string, so `bun test && oxfmt --write src` passes on the strength of its first half and mutates on its second.

That last class is the damaging one. The work gate runs the command and then checks the worktree is clean; a formatter in the gate dirties it, and the stage fails for a reason that has nothing to do with the work. The operator sees a failed work gate, not a bad gate command.

The mitigations that exist are real but partial: `--validate-cmd` overrides the derivation entirely, and the pipeline logs the command it derived. Both require the operator to already suspect the pick.

## Scope

`home/private_dot_claude/dot_smithers/workflows/lib/plan.ts` — `KEEP_TOKENS`, `FORBID_SIGNALS`, `isRunnableVerification`, with tests in `plan.test.ts` covering each line of the table above.

## Open decisions

- **Whether to classify by the runner or by the whole line.** The information the filter actually wants is the first executable word (`oxlint`, `oxfmt`, `bun`) plus its flags, not a bag of tokens from the entire string including file paths. Parsing the head of the command would fix the accidental-keep and the fixtures-collision at once, and would let a compound line be judged per segment.
- **Whether mutation should be detected by flag rather than by tool name.** `--write`, `-w`, `--fix` and `--in-place` are the shared vocabulary; a name list will always trail the next formatter. A flag list is not complete either, but it fails toward refusing rather than toward mutating.
- **Whether an unrecognised runner should be dropped or surfaced.** Dropping is silent, which is how the lint gate nearly vanished. Refusing the launch is loud but blocks on a false positive. A third option is to keep the command and record in the run notes that the filter did not recognise its runner.
- **Whether this filter should exist at all.** The plan is a trusted operator-authored input (KTD8's stated position), and the filter exists to catch prose accidentally read as a command. If the shape fix in `docs/issues/2026-08-14-011-verification-contract-parser-ignores-bullet-lists.md` restricts extraction to structured positions only — table cells, fenced lines, list items — then most of the prose risk is already gone and the filter can be much narrower.

## Resolution

The filter no longer judges the command line as a bag of tokens. It splits the line into shell segments (`&&`, `||`, `;`, `|`, parens — reusing the quote-aware `splitSegments` already in `workflows/lib/validate-probe.ts`) and judges each segment on ONE word: the runner, or the subcommand for a package-manager front-end (`bun test` → `test`, `npm run test:unit` → `test:unit`, `make lint` → `lint`). Leading `VAR=value` assignments and wrappers (`timeout 120 …`, `env …`) are skipped, and the runner is reduced to its basename. A command is kept when every segment is acceptable and at least one segment can carry a verification. File paths and flag values no longer enter the decision at all, which removes both the accidental keep (a filename containing `test`) and the `fixtures`/`fix` collision.

Changed files:

- `home/private_dot_claude/dot_smithers/workflows/lib/plan.ts` — new segment classifier; new exported `deriveValidateCmd(markdown): ValidateCmdDerivation` returning `{ cmd, notes, dropped }`; `extractValidateCmd` kept as a thin wrapper over it, same signature and behaviour, so `se-pipeline.tsx` is untouched.
- `home/private_dot_claude/dot_smithers/workflows/lib/plan.test.ts` — every line of the reproduction table above is an explicit case, plus the read-only-formatter waiver, negated/prefixed flag forms, and the workspace `-w` case. All pre-existing tests pass unchanged.

The four open decisions were settled as:

- **Classify by the runner, per shell segment.** `cd <path>` is neutral so the deliberate `cd pkg && bun test` shape survives. Keeping is decided by an explicit set of verification runners (`tsc`, `jest`, `vitest`, `pytest`, `eslint`, `oxlint`, `biome`, `ruff`, `mypy`, `clippy`, `test`, `typecheck`, `lint`, `check`, …) plus a substring rule applied to the runner word only (`test|lint|check|typecheck|tsc|spec`), which is what keeps `oxlint`. The single-bare-word guard stays: a lone word is runnable only if it is `tsc`, `pytest`, or `jest`.
- **Detect mutation by flag.** `--write`, `-w`, `--fix`, `--in-place`, `-i`, `--apply`, `--overwrite`, matched as whole arguments after the runner word, so `--no-fix`, `--fix-type` and `--fix-dry-run` do not fire and a path containing `fixtures` cannot. A mutating flag always beats a read-only flag in the same segment. The `fix`/`format` NAME signals survive as runner-word matches only, waived when the segment carries a read-only flag (`prettier --check .` is a gate).
- **Surface an unrecognised runner, never drop it.** A segment whose runner matches nothing is kept and recorded in `notes` naming the command and the runner. Symmetrically, nothing is dropped silently: every refused command lands in `dropped` with an actionable reason. A small explicit set of recognised non-verification runners (lifecycle subcommands `install`/`build`/…, and inspection utilities `jq`/`echo`/`cat`/…) is neutral rather than unknown, so `bun install && bun test` stays a gate while a lone `bun build …` or the `jq` coverage line of run-1784823010502 does not become one.
- **The filter stays.** Not coupled to issue 011.

The surfacing is wired: gate 0 (`workflows/se-pipeline.tsx`) derives through `deriveValidateCmd` and writes every dropped command with its reason, and every unrecognised runner, to the run log next to the derived command and into the run summary's notes — the durable copy, because a dropped gate is invisible exactly when nobody re-reads the log. A derivation that yields nothing now names what it refused in the gate-0 refusal message. The gate-0 row carries the observations in a nullish `derivationNotes` field, so a run persisted before the change still resumes. `extractValidateCmd` stays as the terse accessor for a caller that wants only the command.
