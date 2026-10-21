# Report shape

The audit is `~/.claude/artifacts/<ISSUE-ID>/issue.html`, filled from `~/.claude/shared/pf-cycle-pages/issue.html` on the render kit, in the user's language. The template owns the sections and their markup; this file says what fills each one. Every view sits beside the sentence it supports. Skip a section that has nothing to say; keep the order and the ids.

1. **The gist** (`#gist`) — four sentences: what the issue claims, what holds, what does not, what the fix really is.
2. **How it works now** (`#now`) — a Mermaid sequence diagram or call tree of the runtime path, then a table of what each side returns and which rule decides it.
3. **What the contracts say** (`#contracts`) — one claim card per touched contract: the governing line quoted, whether prose and artifact agree, whether the contract intends the behaviour or is silent. State plainly when the fix is a contract change that needs the owner.
4. **The problem** (`#problem`) — pseudocode of the faulty path, the numbered defects, the symptom classification (data leak / wording leak / declared behaviour / stale prose / invalid fixture).
5. **Where it came from** (`#origin`) — commit / PR / date table and the one-line verdict: deliberate or accidental.
6. **What any fix touches** (`#blast`) — file tree with `#` comments for the blast radius; the non-obvious places.
7. **Options** (`#options`) — one card per option with a `diff` or pseudocode sketch and the validator's frames when a prototype was rendered, then a comparison table over the eight lines of step 3 (mechanism, fixes/leaves, who loses what, boundary kind, pinned test, contract impact + classifier line, blocking gate, unknowns).
8. **Validation** (`#validation`) — per validated candidate: verdict, required changes, what stayed UNVERIFIED and why. For an option not validated, one line on why its verdict could not change the choice.
9. **Recommendation** (`#recommendation`) — the option, its reason, a numbered work order, and which contracts change or stay untouched. `/pf-spec` reads this section.
10. **Decided and to decide** (`#decisions`) — two short lists; the second holds exactly the decisions the user must make.
11. **Nearby, out of scope** (`#nearby`) — follow-up candidates in ticket-ready form (summary / observed / done-when) and the list of things you did not verify.
12. **Next** (`#next`) — one handoff line the user can type.

Build with `python3 ~/.claude/shared/render-kit/assemble.py issue.html -o build/issue.html`, then `open build/issue.html`. Chat summary after that: under fifteen lines, verdict first, then the recommendation and the decision left to the user.
