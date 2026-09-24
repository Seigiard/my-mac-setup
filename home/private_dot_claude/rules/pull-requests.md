## Pull Requests

<important if="you are writing or rewriting a PR title or description, or finishing a PR">

- Write for a zero-context reviewer: they see only the diff, not this session, plans, or reviews. Self-contained: what changed, why, how verified.
- Never reference plan unit IDs (U1, KTD-…), review runIds, or other session artifacts — the reviewer cannot interpret them.
- Reference `docs/plans/`, `docs/ideation/`, `docs/brainstorms/` only when those files are committed in the repo (check with `git ls-files <path>`); where they are gitignored, the reviewer cannot open them.
- Even when a plan link is valid, translate the plan's rationale into the description — the description must stand without the link.
- Load the `make-pr` skill before writing or rewriting a PR body. It owns the delivery flow and the body template.
- When the repository states its own PR format, the two merge instead of competing: keep the repository's headings, and place the skill's slots inside them — the non-engineer block first, the one-way/two-way line, `Related:`, and the word cap.

</important>
