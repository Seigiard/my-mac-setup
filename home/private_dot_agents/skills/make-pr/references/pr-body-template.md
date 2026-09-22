<!-- Zero-context reviewer: they see only the diff. Around 350 words outside code blocks. Link only files committed in the repo; session artifacts, plan unit IDs, and review run IDs stay out. -->

{stakeholder block from explain-for-manager, verbatim, as the first paragraph}

## Why

{Exactly one sentence: the problem this PR solves and what becomes possible after it ships.}

## Watch out for

**Door:** {one-way | two-way}. {One clause on why: what a revert leaves behind, or "a plain revert restores the previous state".}

- {1 to 3 bullets: reviewer warnings, migrations, compatibility constraints, deliberate omissions, surprising decisions. "None." when there are none.}

## Shape of the change

{At most two show-me views, each next to one sentence of prose: pseudocode, call tree, component tree, shallow file tree, or Mermaid. A `diff` block when the surrounding shape already exists; the whole block when most of it is new. Never a file-by-file changelog.}

## Evidence

- **Before:** {the failing test, output, or screenshot, named by suite or command}
- **After:** {the passing run, named the same way}

{One line on what is CI-only or not run. Suites and outcomes, never a list of test names.}

Related: {Fixes #N, ADR path, or omit this line}
