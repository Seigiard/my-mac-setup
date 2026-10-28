## Commits

Reached from the commit pointer in `~/.claude/CLAUDE.md` and from the `implement` and `make-pr` skills.

A commit is one concern a reviewer reads on its own. Slice the working tree by concern at file level: tests, implementation, documentation, a migration, a mechanical rename. A change that fits one concern is one commit; split only where a reader gains from reading the parts apart. A caller may name a slice outright, such as the locked test paths of a `tdd` run, and that slice stays as named.

The subject is imperative and names the outcome: what now works, or what is fixed. Match the convention the repository's recent log shows; without one, use conventional commits, with `fix:` for broken or missing behavior and `feat:` for a new capability. A body states motivation or trade-offs the subject cannot carry, and nothing else.

Write the message to a file outside the repository and commit each slice by its named paths, so index entries outside the slice stay where they are:

```bash
git add <paths of the slice>
git commit -F <message-file> -- <paths of the slice>
```

Confirm with `git status` and report each hash with its subject. Whether to push or open a PR follows the two-way-door rule in `~/.claude/CLAUDE.md`.
