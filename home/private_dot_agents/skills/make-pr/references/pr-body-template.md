<!-- Zero-context reviewer: they see only the diff. Around 350 words outside code blocks. Link only files committed in the repo; session artifacts, plan unit IDs, and review run IDs stay out. When the repository defines its own PR sections, keep those headings and place each slot below under the section it belongs to; the slot rules still apply. -->

{stakeholder block from explain-for-manager, verbatim, as the first paragraph}

## Why

{Exactly one sentence: the problem this PR solves and what becomes possible after it ships.}

## Watch out for

**Door:** {one-way | two-way}. {Always one sentence: what a plain revert restores and what it leaves behind. Rows, columns, sent messages, external registrations, or consumed migrations that a revert does not undo make it one-way. "two-way" with no sentence is not an answer.}

- {1 to 3 bullets: reviewer warnings, migrations, compatibility constraints, deliberate omissions, surprising decisions. "None." when there are none.}

## Shape of the change

{At most two show-me views, each next to one sentence of prose: pseudocode, call tree, component tree, shallow file tree, or Mermaid. A `diff` block when the surrounding shape already exists; the whole block when most of it is new. Never a file-by-file changelog.}

## Evidence

- **Before:** {the failing test, output, or screenshot, named by suite or command}
- **After:** {the passing run, named the same way}
- **Visuals:** {`![caption](URL)` per frame from the evidence step, or the walkthrough link, or "no visible surface: see the run above"}

{One line on what is CI-only or not run. Suites and outcomes, never a list of test names.}

Related: {ticket key exactly as the repository writes it (ABC-123), then PR numbers (#N); omit the line when there is neither}
