# Domain Docs

This is a single-context repository. These rules define how engineering skills consume its domain documentation.

## Before exploring, read these

- **`CONCEPTS.md`** at the repository root: the current shared domain vocabulary.
- **`CONTEXT.md`** at the repository root, if introduced later: broader domain context beyond the glossary.
- **`docs/decisions/`**: read decisions that touch the area being changed.

If one of these paths does not exist, proceed silently. Do not suggest creating it up front. The `domain-modeling` skill creates or extends domain documentation when terminology or architectural decisions are actually resolved.

## File structure

```text
/
├── CONCEPTS.md
├── CONTEXT.md              # optional, created only when needed
├── docs/
│   └── decisions/
│       ├── 0001-example-decision.md
│       └── 0002-another-decision.md
└── home/
```

Architectural decisions belong in `docs/decisions/`; do not create a parallel `docs/adr/` tree.

## Use the glossary's vocabulary

When output names a domain concept in an issue title, refactor proposal, hypothesis, or test name, use the term defined in `CONCEPTS.md` or `CONTEXT.md`. Do not drift to synonyms those documents explicitly avoid.

If a needed concept is absent, reconsider whether the project uses that language. If the gap is real, note it for `domain-modeling`.

## Flag decision conflicts

If proposed work contradicts an existing decision, surface the conflict explicitly rather than silently overriding it:

> Contradicts decision 0003, but may be worth reopening because...
