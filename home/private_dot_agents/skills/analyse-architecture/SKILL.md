---
name: analyse-architecture
description: Propose a clearer split of a codebase into modules, from the import graph and co-change history. Use when the user asks to analyse the architecture, asks which modules to merge, split, or move, reports import cycles or changes that ripple across modules, or asks in Russian («проанализируй архитектуру», «как разбить на модули», «связанность модулей»).
---

# Analyse architecture

Judge the **floor plan**: where the seams between modules sit, which knowledge each module owns, and which way dependencies point. Depth inside one module is a different question; for it, point the user to `/improve-codebase-architecture`.

The output is a proposal. Leave the code unchanged.

## Vocabulary and criteria

- Call the Skill tool with `codebase-design`. This skill's work lives in three of its terms: **module**, **interface**, **seam**.
- Call the Skill tool with `module-boundaries`. It supplies the verdict criteria: merge signals, split signals, the third option, and the shared-information criterion (which module is the authoritative owner of the knowledge). Where it says "boundary", write **seam**.
- Read `GLOSSARY.md` and `docs/adr/` when the repository has them. Name modules with glossary terms.

## Steps

### 1. Draw the current map

Take the area the user named; otherwise take the whole repository. Pick the level at which people talk about the code: `packages/*`, `src/features/*`, top-level app areas. Write one line per module: its path and the knowledge it owns.

Done when every source file in scope belongs to exactly one module, or is declared out of scope (generated, vendored, build output). Tests under a module's path belong to it; a test tree outside every module path is out of scope for the tables, and the map says so.

### 2. Collect evidence

Run `<skill-dir>/scripts/modules.py` with the analysed repository's root as the working directory. Pass the map from step 1 as one `--module` per module, so both tables use the same modules.

```bash
python3 <skill-dir>/scripts/modules.py cochange --module src/features/auth --module src/shared/api ...
```

`cochange` reads `git log` for the last 12 months and skips bulk commits (renames, formatting); override with `--since` and `--max-files`.

For the import graph, produce a JSON object `{file: [imported files]}`:

- JavaScript and TypeScript: `npx -y madge@8.0.0 --json --extensions ts,tsx,js,jsx --ts-config tsconfig.json src > "$TMPDIR/graph.json"`. madge prints paths relative to the directory it scanned, so pass `--prefix src` below. Drop `--ts-config` when the project has none.
- Other languages: build the same JSON from the language's own tool (`go list -deps -json`, `pydeps --show-deps`, `jdeps`) or from import statements.

```bash
python3 <skill-dir>/scripts/modules.py imports "$TMPDIR/graph.json" --prefix src --module src/features/auth ...
```

Done when both tables exist for the scope, or the map records which one is missing and why (no history, no import tool for the language), for the page in step 5.

### 3. Judge the suspects

A **suspect** is any of:

- a pair with `ratio` ≥ 0.3 (the script already drops pairs under `--min-together`);
- a two-way pair or a cycle;
- an edge from general code to specific code (shared → feature, domain → UI, library → app);
- a module with more external than internal imports, or with the highest fan-in and fan-out together;
- a module whose parts change apart: rerun `cochange --scope <module> --depth <one level deeper>`; parts whose pairs stay under the ratio threshold change apart. A part with fewer than 3 commits is unknown, not independent.

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

Done when every suspect has a verdict that names the knowledge involved and cites its numbers from step 2. Where a table is missing, the verdict names the criterion it could not check.

### 4. Write the target map

Turn the verdicts into **moves**, ordered so that a move that unblocks others comes first, then cheaper before costlier. Each move carries:

- the files and modules it touches;
- the evidence: numbers from step 2 and the named knowledge from step 3;
- the expected effect on the numbers: a cycle gone, a co-change pair now inside one module, an edge reversed;
- strength: `Strong` when the code and the numbers both support it and no open question could change the verdict; `Worth exploring` when a named open question could; `Speculative` when a named hypothesis still lacks evidence;
- the cost: files moved, imports rewritten, public interfaces changed;
- the ADR it contradicts, when there is one; propose such a move only at `Strong`.

A move names the seam; the shape of the interface at that seam is decided in step 6.

Done when every verdict other than `keep` is a move with all its fields.

### 5. Report

Read `~/.claude/shared/render-kit.md` and build the page by its assembly contract. Publish it by calling the Skill tool with `agent-reports`, with the repository's name as the project. Sections, in order:

1. **Summary**: the move to make first and why, in three sentences.
2. **Current map**: the modules, and a Mermaid flowchart of module edges with cycles highlighted.
3. **Evidence**: the co-change and import tables, trimmed to the suspects.
4. **Moves**: one `article` per move with the fields from step 4.
5. **Target map**: the Mermaid flowchart after all `Strong` moves.
6. **Kept as is**: suspects with a `keep` verdict and the reason.

When no move survives step 4, the summary says why the current split holds, the target map is the current map, and the Moves section is omitted.

In chat, give the link and the first move in one line, then ask which move to explore. With no moves, give the link and that conclusion.

### 6. Explore the chosen move

When the user picks a move, call the Skill tool with `grilling` to settle its shape: what crosses the new seam, what stays private, which tests survive. Done when the move carries those three answers.
