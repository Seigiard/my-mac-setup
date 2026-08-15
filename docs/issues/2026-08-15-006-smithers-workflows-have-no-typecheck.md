---
title: The Smithers workflows package has no tsconfig, so nothing type-checks it and the editor reports phantom errors
type: chore
date: 2026-08-15
status: done
closed: 2026-08-15
---

# The workflows package has no tsconfig, so nobody type-checks it

## Why this exists

`home/private_dot_claude/dot_smithers/` holds ~9,500 lines of TypeScript that gate real spend, publish pull requests and enforce a secret boundary. It has no `tsconfig.json` and no `@types/bun`; its `devDependencies` carry `@types/node` alone.

Two consequences, and the second is the expensive one.

**The editor reports errors that are not there.** The TypeScript language server has no `types` and no `moduleResolution` to work from, so it cannot resolve bun's built-in modules or pick up the `@types/node` that is already installed:

```
se-pipeline.tsx:16   Cannot find module 'bun:sqlite' … [2307]
gates.test.ts:1      Cannot find module 'bun:test' … [2307]
staging.ts:9         Cannot find name 'node:child_process' … [2591]
staging.ts:141       Cannot find namespace 'NodeJS'. [2503]
envelopes.test.ts:109 Cannot find name 'Bun'. [2868]
standalone-secret-gate.test.ts:10 Property 'dir' does not exist on type 'ImportMeta'. [2339]
```

None of these is a real defect. Bun resolves every one of those modules at runtime: `bun test` reports 584 pass / 0 fail and `bun build workflows/se-pipeline.tsx` bundles 724 modules. But an editor that cries wolf on every file trains its reader to ignore it, which is exactly when a real type error lands unnoticed.

**Nothing type-checks the package.** With no tsconfig, `tsc --noEmit` cannot simply be run — it has to be invoked with the whole configuration on the command line:

```
bunx tsc --noEmit --strict --skipLibCheck --target esnext --module preserve \
  --moduleResolution bundler --allowImportingTsExtensions --jsx react-jsx \
  --jsxImportSource smithers-orchestrator workflows/se-pipeline.tsx …
```

So no one does. Verification in this package is `bun test` plus `bun build`, and `bun build` explicitly does not type-check: it resolves the module graph and never instantiates anything. `docs/issues/2026-08-14-004-se-flow-stalls-after-staging-and-epilog-gaps.md` recorded the cost of that gap — a workflow declared an output field named `runId`, which Smithers reserves, and every launch was refused for a day while the build stayed green. `workflows/workflow-construction.test.ts` was added to catch that class at import time; a type-check would have caught it at edit time.

Two real type errors are known to exist behind the noise, both in `se-flow.tsx` and both predating today's work: `Type 'unknown' is not assignable to type 'AgentLike'` at the block agent prop, and the same for `OutputTarget` at its output prop. They have never been triaged because no one can see them.

## Scope

- `home/private_dot_claude/dot_smithers/package.json` — add `@types/bun` to `devDependencies`.
- `home/private_dot_claude/dot_smithers/tsconfig.json` — new. It must match how bun actually runs this code: `strict`, `target esnext`, `module preserve`, `moduleResolution bundler`, `allowImportingTsExtensions`, `jsx react-jsx`, `jsxImportSource smithers-orchestrator`, `types: ["bun"]`. `skipLibCheck` on, because the errors worth seeing are in this package, not in `node_modules`.
- `tests/smoke.bats` — a smoke test, per the repo's rule that a new managed file gets one.
- `docs/se-pipeline.md` — the verification commands section, which currently names only `bun test`.

## Open decisions

- **Whether the type-check joins CI.** The suite here runs under bun in Docker and macOS; adding `tsc --noEmit` is one more command, but it fails today on the two `se-flow.tsx` errors, so it has to be either fixed or explicitly baselined before it can gate anything.
- **What to do with the two known `unknown`-typed JSX props.** Fixing them properly may mean typing the block registry's `makeAgent`/output plumbing, which is more than a config change; casting them silences the check and keeps the class of error alive.

## Resolution

`home/private_dot_claude/dot_smithers/tsconfig.json` now exists and `@types/bun` is a devDependency. The config describes how bun already runs this code rather than a build target — `module: preserve`, `moduleResolution: bundler`, `allowImportingTsExtensions`, `jsx: react-jsx` with `jsxImportSource: smithers-orchestrator`, `types: ["bun"]`, `strict`, `skipLibCheck`. `bunx tsc --noEmit` is now a bare command instead of an eight-flag incantation, and the editor is quiet.

Seven real type errors were behind the noise. All are fixed; `bunx tsc --noEmit` reports **zero**.

- `block-registry.ts` declared `makeAgent: (build: AgentBuild) => unknown`, and the interpreter hands that value straight to a Task's `agent` prop. It is now `ClaudeCodeAgent | OpenCodeAgent`, with `implementationAgent` in `lib/blocks/index.ts` typed to match. This was one of the two errors this issue predicted would need real typing rather than a cast.
- `se-flow.tsx`'s `mirrorOutput` returned `unknown` into a Subflow's `output` prop; it now names the union of the three declared mirror targets.
- `agents.test.ts` used `test.each` over a `readonly` tuple of profile names. Bun's `each()` widens its parameter to `unknown`, which cannot index `AGENT_PROFILES`, so the lookup was never checked. Replaced with a plain `for` loop, which keeps the name a literal.
- `cost.test.ts` passed a bare string where `Database.run` takes a bindings array.
- `block-registry.test.ts`'s fixture returns `{}` for `makeAgent`. That one IS a cast, with a comment: those tests register and read definitions and never dispatch one.

Two smoke tests in `tests/smoke.bats` keep both halves in place: the tsconfig exists and agrees with the JSX runtime, and `@types/bun` stays declared. `docs/se-pipeline.md`'s dev-cycle section now names all three verification commands and what each does NOT catch.

The first open decision — whether the type-check joins CI — is deliberately left open. It is now possible (the check is clean and one command), but adding it is a CI change with its own failure modes, and this issue's job was to make type errors visible. The second is answered above: the two known errors were typed properly, not cast.
