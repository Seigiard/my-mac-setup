<!-- Rule: ~/.claude/shared/pull-requests.md. At most 500 words outside code blocks. The sections are exactly the ones below, in this order; the body ends at the Related line, or at the Evidence section when there is none. The harness attribution lines go on commit messages; every sentence of the body is about the work. -->

{stakeholder block from explain-for-manager, verbatim, as the first paragraph}

## Why

{The problem this PR solves, then what shipping it makes possible.}

## Watch out for

**Door:** {one-way | two-way}. {Always: what a plain revert restores and what it leaves behind. Anything left behind, such as rows, columns, sent messages, or external registrations, makes the door one-way.}

{With nothing to warn about, the Door line stands alone. Otherwise one bullet per warning: reviewer warnings, migrations, compatibility constraints, deliberate omissions, surprising decisions.}

## Shape of the change

{At most two show-me views, each beside the prose that says what the view shows: pseudocode, call tree, component tree, shallow file tree, or Mermaid. A `diff` block when the surrounding shape already exists; the whole block when most of it is new. Views show shape; the file list belongs to the diff itself.}

## Evidence

- **Before:** {the failing test, output, or screenshot, named by suite or command}
- **After:** {the passing run, named the same way}
- **Visuals:** {per frame from the evidence step, `![caption](URL)` or the `![caption](path)` that `--attach` rewrites; or the walkthrough link; or "no visible surface: see the run above"}

{When a check ran only in CI or did not run, one line naming the suite and its outcome; otherwise nothing.}

Related: {ticket key exactly as the repository writes it (ABC-123), then the PRs and issues this PR closes or continues (#N), then `later: #N` for each tracked issue this PR leaves for later; omit the line when there is none}
