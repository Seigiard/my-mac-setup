---
name: analyse-architecture
description: Analyse how a codebase is split into modules and propose a clearer split, from the import graph and co-change history. Use when the user asks to analyse architecture or module structure, asks which modules to merge, split, or re-own, reports tangled modules, import cycles, or changes that ripple across modules, or asks in Russian («проанализируй архитектуру», «как разбить на модули», «связанность модулей»).
---

# Analyse architecture

Judge the **floor plan**: where the seams between modules sit, which knowledge each module owns, and which way dependencies point. Depth inside one module is a different question; for it, point the user to `/improve-codebase-architecture`.

The output is a proposal. Leave the code unchanged.

## Vocabulary and criteria

- Call the Skill tool with `codebase-design` and use its terms exactly: **module**, **interface**, **seam**, **depth**, **locality**, **leverage**.
- Call the Skill tool with `module-boundaries`. It supplies the verdict criteria: merge signals, split signals, the third option, and the knowledge-owner criterion. Where it says "boundary", write **seam**.
- Read `GLOSSARY.md` and `docs/adr/` when the repository has them. Name modules with glossary terms. Propose a move that contradicts an ADR only when the evidence is strong, and mark the contradiction on the move.

## Steps

### 1. Draw the current map

Take the area the user named; otherwise take the whole repository. Pick the level at which people talk about the code: `packages/*`, `src/features/*`, top-level app areas. Write one line per module: its path and the knowledge it owns.

Done when every source file in scope belongs to exactly one module, or is declared out of scope (generated, vendored, build output). Tests belong to the module they test.

### 2. Collect evidence

Run `scripts/modules.py` from this skill's directory, at the root of the analysed repository. Pass the map from step 1 as one `--module` per module, so both tables use the same modules.

```bash
python3 <skill-dir>/scripts/modules.py cochange --module src/features/auth --module src/shared/api ...
```

`cochange` reads `git log` (default `--since "12 months ago"`; it skips commits that touch more than 50 files). Per pair it reports `together`, the commits that changed both modules, and `ratio`, `together` divided by the commit count of the smaller module. A ratio of 0.5 means half the changes to the smaller module also changed the other.

For the import graph, produce a JSON object `{file: [imported files]}`:

- JavaScript and TypeScript: `npx -y madge@8.0.0 --json --extensions ts,tsx,js,jsx --ts-config tsconfig.json src > "$TMPDIR/graph.json"`. madge prints paths relative to the directory it scanned, so pass `--prefix src` below. Drop `--ts-config` when the project has none.
- Other languages: build the same JSON from the language's own tool (`go list -deps -json`, `pydeps --show-deps`, `jdeps`) or from import statements.

```bash
python3 <skill-dir>/scripts/modules.py imports "$TMPDIR/graph.json" --prefix src --module src/features/auth ...
```

`imports` reports module edges with import counts, two-way pairs, cycles between modules, and per module its fan-in, fan-out, and internal against external imports.

Done when both reports exist for the scope, or the report names the missing one and why (no history, no import tool for the language).

### 3. Judge the suspects

A **suspect** is any of:

- a pair with `ratio` ≥ 0.3 and `together` ≥ 3;
- a two-way pair or a cycle;
- an edge from general code to specific code (shared → feature, domain → UI, library → app);
- a module with more external than internal imports, or with the highest fan-in and fan-out together;
- a module whose files fall into groups that never change together.

For each suspect, read the code and name the knowledge each side owns and the knowledge it borrows: a data shape, a format, a protocol, a business rule. Then apply the `module-boundaries` criteria. For a large scope, dispatch one subagent per cluster of suspects with the question "which knowledge does each module own, and which does it borrow from the other?", and judge from their answers.

Each suspect gets one verdict:

| Verdict | Meaning |
|---|---|
| merge | the seam is fiction: the modules share knowledge and change together |
| split | one module holds two pieces of knowledge that change apart |
| extract | the shared knowledge is a third concept; name it and give it its own module |
| move | code sits away from the module that owns its knowledge |
| invert | the dependency points from general to specific; turn it around |
| keep | the coupling is real and cheap; state why |

Done when every suspect has a verdict that cites its numbers from step 2 and names the knowledge involved.

### 4. Write the target map

Turn the verdicts into **moves**, ordered so that a move that unblocks others comes first, then cheaper before costlier. Each move carries:

- the files and modules it touches;
- the evidence: numbers from step 2 and the named knowledge from step 3;
- the expected effect on the numbers: a cycle gone, a co-change pair now inside one module, an edge reversed;
- strength: `Strong`, `Worth exploring`, or `Speculative`;
- the cost: files moved, imports rewritten, public interfaces changed.

A move names the seam; the shape of the interface at that seam is decided later.

### 5. Report

Build an HTML page on the render kit (`~/.claude/shared/render-kit.md`) and publish it through the `agent-reports` skill with the repository's name as the project. Sections, in order:

1. **Summary**: the move to make first and why, in three sentences.
2. **Current map**: the modules, and a Mermaid flowchart of module edges with cycles highlighted.
3. **Evidence**: the co-change and import tables, trimmed to the suspects.
4. **Moves**: one `article` per move with the fields from step 4.
5. **Target map**: the Mermaid flowchart after all `Strong` moves.
6. **Kept as is**: suspects with a `keep` verdict and the reason.

In chat, give the link, the first move in one line, and ask which move to explore.

### 6. Explore the chosen move

When the user picks a move, call the Skill tool with `grilling` to settle its shape: what crosses the new seam, what stays private, which tests survive. To compare interface shapes for a new or merged module, use the design-it-twice pattern from `codebase-design`.
