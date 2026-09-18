# Report shape

Markdown at `~/.claude/artifacts/<ISSUE-ID>/issue.md`, user's language, every view placed beside the sentence it supports (show-me). Skip a section that has nothing to say; keep the order.

1. **Суть** — four sentences: what the issue claims, what holds, what does not, what the fix really is.
2. **Как работает сейчас** — a Mermaid sequence diagram or call tree of the runtime path, then a table of what each side returns and which rule decides it.
3. **Что говорят контракты** — for each touched contract: the governing line quoted, whether prose and artifact agree, whether the contract intends the behaviour or is silent. State plainly when the fix is a contract change that needs the owner.
4. **В чём проблема** — pseudocode of the faulty path, the numbered defects, the symptom classification (data leak / wording leak / declared behaviour / stale prose / invalid fixture).
5. **Откуда это взялось** — commit / PR / date table and the one-line verdict: deliberate or accidental.
6. **Что затронет любое решение** — file tree with `#` comments for the blast radius; the non-obvious places.
7. **Варианты** — one subsection per option with a `diff` or pseudocode sketch, then a comparison table over the eight lines of step 3 (mechanism, fixes/leaves, who loses what, boundary kind, pinned test, contract impact + classifier line, blocking gate, unknowns).
8. **Проверка** — per validated candidate: verdict, required changes, what stayed UNVERIFIED and why.
9. **Рекомендация** — the option, its reason, a numbered work order, and which contracts change or stay untouched.
10. **Что я решил сам / Что решаешь ты** — two short lists; the second holds exactly the decisions the user must make.
11. **Рядом, но вне задачи** — follow-up candidates in ticket-ready form (summary / observed / done-when) and the list of things you did not verify.
12. **Что дальше** — one handoff line the user can type.

Chat summary after `open`: under fifteen lines, verdict first, then the recommendation and the decision left to the user.
