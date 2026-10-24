<!-- Zero-context reviewer: they see only the diff. At most 500 words outside code blocks. Link only files committed in the repo; session artifacts, plan unit IDs, and review run IDs stay out. The body ends at the Related line, or at the Evidence section when there is none. -->

{stakeholder block from explain-for-manager, verbatim, as the first paragraph}

## Why

{The problem this PR solves, and what becomes possible after it ships: each its own plain sentence, taken in on first reading.}

## Watch out for

**Door:** {one-way | two-way}. {One sentence, always: what a plain revert restores and what it leaves behind. Anything left behind, such as rows, columns, sent messages, or external registrations, makes the door one-way.}

- {Bullets only when there is something to warn about: reviewer warnings, migrations, compatibility constraints, deliberate omissions, surprising decisions. With nothing to warn about, the Door line stands alone.}

## Shape of the change

{At most two show-me views, each next to one sentence of prose: pseudocode, call tree, component tree, shallow file tree, or Mermaid. A `diff` block when the surrounding shape already exists; the whole block when most of it is new. Views show shape; the file list belongs to the diff itself.}

## Evidence

- **Before:** {the failing test, output, or screenshot, named by suite or command}
- **After:** {the passing run, named the same way}
- **Visuals:** {per frame from the evidence step, `![caption](URL)` or the `![caption](path)` that `--attach` rewrites; or the walkthrough link; or "no visible surface: see the run above"}

{One line on what is CI-only or not run. Suites and outcomes, never a list of test names.}

Related: {ticket key exactly as the repository writes it (ABC-123), then PR numbers (#N), then the tracked issues for work this PR leaves for later; omit the line when there is none}

<!-- Work left for later is a tracked issue on the Related line. The body has no Follow-ups section and no other section the template does not name. -->
