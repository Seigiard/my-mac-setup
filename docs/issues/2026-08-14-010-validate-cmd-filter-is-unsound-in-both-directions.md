---
title: The validate-command filter judges commands by substring, so it drops real gates and admits mutating ones
type: bug
date: 2026-08-14
status: open
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
- **Whether this filter should exist at all.** The plan is a trusted operator-authored input (KTD8's stated position), and the filter exists to catch prose accidentally read as a command. If the shape fix in `docs/issues/2026-08-14-009-verification-contract-parser-ignores-bullet-lists.md` restricts extraction to structured positions only — table cells, fenced lines, list items — then most of the prose risk is already gone and the filter can be much narrower.
