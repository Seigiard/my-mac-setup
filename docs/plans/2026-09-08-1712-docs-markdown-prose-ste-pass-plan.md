---
title: Markdown Prose Pass With Simplified Technical English - Plan
type: docs
date: 2026-09-08
topic: markdown-prose-ste-pass
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Markdown Prose Pass With Simplified Technical English - Plan

## Goal Capsule

- Objective: a reader who opens this repository's front-page and vocabulary documents reads prose that follows the sentence rules the repository already asks its agents to follow, and no agent changes its behavior because of the edit.
- Means: run the CHECK discipline of the MIT-licensed `simple-english` skill against a frozen, English-only, non-historical target list, and split the list into files that may be edited directly and files that only receive a report (KTD2, KTD6).
- Authority: `CLAUDE.md` and `docs/agent-verification.md` govern repository conventions and outrank this plan where they conflict. `home/.chezmoitemplates/writing-style.md` is the repository's own style authority and outranks the ASD-STE100 catalog where the two disagree (KTD6).
- Execution profile: four dependency-ordered units. Unit U4 is gated on explicit user approval of the U3 report and does not run without it.
- Stop conditions: stop and ask if the rule catalog cannot be fetched, if a CHECK finding on a behavior-bearing file cannot be rewritten without changing an instruction's force, or if the vendoring plan for `ste_lint.py` lands mid-run.
- Readiness: both blocking questions are settled, so this plan is implementation-ready. Q3 stays open and is deferred, which does not hold readiness back. One sequencing prerequisite remains, which is that the document-style skill plan must land its vendored catalogue first, and U1 stops if it has not.

---

## Product Contract

### Summary

The repository carries a shared agent writing style at `home/.chezmoitemplates/writing-style.md`. Commit `0c5c33a` extended that style with sentence-level rules: no em-dash, no semicolon, simple tenses, no "-ing" clause after a comma, no contractions, and an eleven-word filler list. The repository's own committed Markdown has never been checked against any of it.

This plan runs one bounded prose pass over a small, deliberately chosen subset of that Markdown. It is a cleanup, not infrastructure. It adds no tool to the managed configuration, no test, and no continuous-integration gate.

The pass is scoped by measurement rather than by intuition. A count of the repository's own literal-scan strings across the candidate files produced the table in Problem Frame, and that table is what reduced the target list from roughly 46,000 words to roughly 5,800.

### Problem Frame

Three facts shape the work.

First, the named mechanism is absent. The `simple-english` skill is not installed in any skill root on this machine, it is not in `home/private_dot_config/agent-skills/manifest`, and it is not in `home/.chezmoiexternal.toml`. CHECK mode cannot be invoked as a skill today. Its rule catalog is reachable as a plain file, which is the whole of what CHECK mode needs (KTD1).

Second, the violation counts are large and concentrated in files that are not worth editing. Prose-only counts, taken with fenced code blocks and inline code spans removed:

| Target | Words | Em-dash | Semicolon | Read on every task | Dated record |
|---|---|---|---|---|---|
| `README.md` | 407 | 12 | 0 | no | no |
| `CONCEPTS.md` | 3446 | 33 | 20 | no | no |
| `CLAUDE.md` | 1505 | 28 | 16 | yes | no |
| `docs/agent-verification.md` | 483 | 0 | 5 | yes | no |
| `docs/solutions/` (18 files) | 39466 | 478 | 289 | no | yes |
| `docs/decisions/` (3 files) | 3867 | 36 | 13 | no | yes |

`docs/solutions/` is 86 percent of the candidate corpus by word count and carries 78 percent of the em-dashes, and every file in it is a dated record of a past incident. `docs/decisions/` holds Architecture Decision Records, which are dated records by definition. Rewriting the prose of a dated record changes the record.

Third, the two highest-value targets are the two riskiest. `CLAUDE.md` and `docs/agent-verification.md` are instruction documents that agents read and follow. `CLAUDE.md` is read on every task in this repository. ASD-STE100 rule 3 bans the modals "should", "would", "may", "might", and "could", and its modal ladder converts a required "should" into "must". Applying that ladder to an instruction document converts advisory language into mandatory language, which is a behavior change wearing the costume of a style fix.

The repository's own style already anticipates this and carries a safety valve the ASD-STE100 catalog lacks: "Keep 'may', 'might', or 'could' only where the uncertainty is real, because 'Make certainty visible' outranks this rule."

### Requirements

Mechanism and grounding

- R1. The pass reads the 53-rule catalog from `skills/simple-english/references/rule-catalog.md` in the upstream `AminBlg/SimpleEnglish` repository before it reports any finding.
- R2. Every reported finding names the rule number quoted from that file, the offending text, and a compliant rewrite. A rule number recalled from memory is not acceptable.
- R3. The pass adds no entry to `home/private_dot_config/agent-skills/manifest`, `home/.chezmoiexternal.toml`, or any other managed path.

Scope and language

- R4. The pass edits only `README.md` and `CONCEPTS.md` without further approval.
- R5. The pass produces a report for `CLAUDE.md` and `docs/agent-verification.md`. The report is the deliverable for these two files. The pass itself edits neither, and any edit is a separate follow-up gated on per-finding approval.
- R6. The pass edits no dated historical record. `docs/solutions/`, `docs/decisions/`, `docs/plans/`, `docs/issues/`, `docs/brainstorms/`, `docs/benchmarks/`, and `docs/ideation/` are out of scope.
- R7. The pass edits no file that contains non-English prose, and it records why rather than reporting such a file as clean.
- R8. The pass never alters code, an identifier, a command, a flag, a file path, quoted text, a product name, or a fact, in line with `home/.chezmoitemplates/writing-style.md`.

Behavior preservation

- R9. No edit changes the force of an instruction. In `CLAUDE.md` and `docs/agent-verification.md` a "should" stays a "should" and a "may", "might" or "could" stays as written, with no exception and no approval path. Converting a modal inside an instruction document is a behaviour change to every agent that reads it, and it is not a style edit.
- R10. No edit changes the meaning of an `<important if=...>` condition, a table row that gates a command choice, or a risk-class definition.

### Success Criteria

Punctuation counts are the necessary condition and not the sufficient one. Risk 1 under Risks is the reason the two are stated apart.

Necessary, and cheap to check:

- Em-dash and semicolon counts in `README.md` and `CONCEPTS.md` reach zero outside code spans, quoted text, and protected literals. Measured baseline is 12 and 0 for `README.md`, and 33 and 20 for `CONCEPTS.md`.
- A reviewer reading `git diff` for the two edited files finds no changed instruction, command, path, or fact.
- The report for the two behavior-bearing files exists and every finding in it carries a rule number, the offending text, and a rewrite.
- A Cyrillic scan over every edited file returns the same count it returned before the edit.

Sufficient, and the part a reviewer must actually judge:

- The structure inventory of every edited file is unchanged, exactly. Measured baselines are 20 headings, 16 list items, 5 fenced blocks and 5 links for `README.md`, and 38 headings, 2 list items, 0 fenced blocks and 0 links for `CONCEPTS.md`. Any drop is the formatting-removal half of Risk 1 and fails the pass.
- Sentence count per file rises by no more than 15 percent. Measured baselines are 19 sentences at a 21.4-word mean for `README.md`, and 134 sentences at a 25.7-word mean for `CONCEPTS.md`. A larger rise is the sentence-splitting half of Risk 1.
- No sentence the pass creates is shorter than about five words. `home/.chezmoitemplates/writing-style.md` states that the goal is short sentences and not telegraph style, and unchecked splitting produces telegraph style.

What the pass will not deliver, stated so that nobody expects it:

- No measurable reduction in filler or slop, because there is almost none to remove. Measured filler across all four targets totals two instances, both of them the word "just", one in `README.md` and one in `CONCEPTS.md`. `CLAUDE.md` and `docs/agent-verification.md` measure zero. This repository's prose is already clean on the axis Risk 1 describes. A diff that claims substantive readability gains in these files is evidence that the editor invented changes rather than found them.

### Scope Boundaries

In scope for direct edit:

- `README.md`
- `CONCEPTS.md`

In scope for a report only:

- `CLAUDE.md`
- `docs/agent-verification.md`

Explicitly out of scope:

- `home/**`. Every file there is chezmoi-managed, so editing one is deployment-sensitive under `docs/agent-verification.md` and would require a `make test-ubuntu` verdict. That cost does not belong in a prose cleanup. This exclusion covers `home/.chezmoitemplates/writing-style.md` itself, which is the authority for this pass rather than a target of it, and the 42 Markdown files under `home/private_dot_agents/skills/`.
- `SYNC-TODO.md`. It is a root-level tracker written in Russian (2281 Cyrillic characters). A sweep that globs root-level Markdown would reach it, so the exclusion is named rather than implied (KTD4).
- All dated records under `docs/`, per R6.
- `AGENTS.md`. It is a symlink to `CLAUDE.md`, so it carries no separate content and needs no separate edit.

#### Deferred to Follow-Up Work

- A prose pass over `docs/solutions/`. It is the largest single block of violations and the lowest value per edit, and its files are dated records. If it ever runs, it should run after the `ste_lint.py` linter lands, so the mechanical rules are found by a program rather than by a reading pass.
- Any continuous-integration prose gate. This plan deliberately ships no gate.
- The em-dash defect in `home/.chezmoitemplates/writing-style.md` described under Dependencies. It is handled separately and must not be fixed here.

### Dependencies

- The upstream rule catalog at `https://raw.githubusercontent.com/aminblg/simpleenglish/HEAD/skills/simple-english/references/rule-catalog.md`. Confirmed reachable on 2026-09-08 (HTTP 200, 1744 words, 53 rules across 9 sections).
- A separate plan vendors `ste_lint.py`, a stdlib-only regex linter from the same upstream repository that mechanically counts em-dashes, semicolons, contractions, perfect tenses, banned modals, and slop words. That plan is not this plan and must not be folded into it. If it lands first, the economics change: the mechanical rules become a program's output, and this pass narrows to the judgment rules only. Sequencing note in U1 covers the case.
- A hard prerequisite, settled on 2026-09-08. `docs/plans/2026-09-08-1712-feat-document-style-skill-plan.md` forks the document-facing half of the same upstream skill into a repository-owned skill under `home/private_dot_agents/skills/` and vendors the rule catalogue with it at a pinned revision. That plan lands first. This pass cannot start until the vendored catalogue exists in the checkout, because KTD1 now reads that file and has no fallback. This is a blocking dependency and not a preference.
- A known defect in `home/.chezmoitemplates/writing-style.md`: the em-dash prohibition adopted in `0c5c33a` is correct for English and wrong for Russian, where the dash is normative punctuation. It is being handled separately. This plan must not propagate the assumption that punctuation rules are language-neutral, which is one of the two reasons for KTD4.

### Outstanding Questions

- Q1 (settled 2026-09-08). Should `CLAUDE.md` and `docs/agent-verification.md` be in the pass, even in report-only form? Answer: yes, in report-only mode. Both files are scanned and every finding is reported and classified. The pass itself applies no edit to either file. An individual edit needs the owner's approval, one finding at a time, and only from the eligible categories in KTD6. The modal ladder, voice conversion and vocabulary substitution stay forbidden in these two files under all circumstances, and no approval makes them available.
- Q2 (closed 2026-09-08 by the Q4 answer). Should this pass wait for the `ste_lint.py` vendoring plan? That plan is `docs/plans/2026-09-08-1714-feat-vendored-prose-lint-target-plan.md`. It is independent of the settled landing order, so this pass does not wait on it. If it happens to land first, U1 step 5 re-scopes the pass to the judgment rules and the mechanical counts come from the linter instead.
- Q3 (deferred). Is `CONCEPTS.md` worth 3446 words of editing attention given that it is read on demand rather than on every task? Dropping it would reduce the pass to `README.md` plus the report.
- Q4 (settled 2026-09-08, recorded for traceability). Landing order among the three in-flight plans. Answer: the document-style skill plan lands first and brings the vendored catalogue, then this pass runs against it. The `ste_lint.py` vendoring plan is independent of that order. Q2 is closed by the same answer and needs no separate decision.

### Sources

- `home/.chezmoitemplates/writing-style.md`, and commit `0c5c33a` which added the sentence-level rules.
- `docs/agent-verification.md`, for the risk classes that determine which checks apply.
- `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md`, for the test-design standard behind KTD5.
- The upstream ASD-STE100 rule catalog named under Dependencies.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Read the rule catalogue from the vendored copy in the repository checkout. Settled by the repository owner on 2026-09-08. `docs/plans/2026-09-08-1712-feat-document-style-skill-plan.md` vendors `references/rule-catalog.md` at a pinned upstream revision inside the skill directory it creates, and this pass reads that file. Fetching the catalogue over HTTP at run time is rejected: the upstream file moves, so two runs of this pass could apply two different rule sets and neither would be reproducible from the repository alone. Installing `AminBlg/SimpleEnglish` into `home/private_dot_config/agent-skills/manifest` remains rejected for the reason it always was, which is that it would add a managed dependency and pull a `make test-ubuntu` verdict onto a cleanup.
  - Read the checkout copy at `home/private_dot_agents/skills/<name>/references/rule-catalog.md`, not the deployed copy at `~/.agents/skills/<name>/references/rule-catalog.md`. The two differ until someone runs `chezmoi apply`, which `CLAUDE.md` forbids on the host. Reading the checkout keeps this pass free of any deployment step and keeps it out of the deployment-sensitive risk class. The `<name>` segment is whatever the sibling plan's ODEC-1 settles, with `document-style` as its stated default.
- KTD2. Split the corpus by whether an agent follows the file, not by how many violations it holds. Cosmetic files are edited. Behavior-bearing files produce a report and nothing else until a human approves each finding. This is the decision that keeps a style pass from silently becoming a behavior change.
- KTD3. Exclude dated records rather than deprioritizing them. A record with a `date:` field describes what was true and what was decided at a point in time. Restyling its prose edits the record. This reasoning removes 43,333 of the roughly 46,000 candidate words and is a stronger boundary than a cost argument.
- KTD4. Exclude non-English prose explicitly and record the exclusion. ASD-STE100 is an English standard: its 53 rules are English grammar and English vocabulary throughout. Run against Russian text it reports close to zero violations, and that output reads as "clean" when it actually means "not measured". A scan of the whole repository found 17 Markdown files containing Cyrillic. None of the four targets contains any. Two files inside the excluded `docs/solutions/` tree contain small quoted Russian fragments, and one of those fragments contains an em-dash inside a quoted Russian title, which a naive em-dash sweep would corrupt. That is the concrete reason this exclusion is stated rather than assumed.
- KTD5. Write zero new tests. The oracle line cannot be completed for this change. There is no consumer whose observable failure a test could detect, because prose style has no runtime behavior. A test asserting that `README.md` contains no em-dash would be a source-shape assertion, an assertion of absence, and would take its expected value from the same patch that creates it. All three are rejected by `docs/solutions/design-patterns/semantic-regression-tests-over-source-shape.md` and by the repository's test-oracle gate. No existing test owns repository prose quality: the two tests that mention the writing style assert only that the file is deployed and referenced.
- KTD6. Restrict which rules may drive an edit, per file class. For the cosmetic files, all 53 rules are advisory and the editor uses judgment. For the behavior-bearing files, only the mechanically safe rules are ever eligible, and only after per-finding approval: em-dash, semicolon, contraction, and simple-tense repair. Rule 3's modal ladder, rule 3.6's voice conversion, and section 1's vocabulary substitutions are forbidden in those two files absolutely. No approval workflow promotes them into scope, because each changes what an instruction requires rather than how it reads. Where the ASD-STE100 catalog and `home/.chezmoitemplates/writing-style.md` disagree, the repository style wins.

### Assumptions

- The user wants the repository's own documents to match the style it asks agents to follow, rather than wanting a reusable enforcement mechanism. A mechanism is the `ste_lint.py` plan's job.
- `README.md` and `CONCEPTS.md` have no external consumer that depends on their exact wording.
- The report produced by U3 is worth having even if the user then declines every finding in it, because it tells them how far the instruction documents sit from the style.

### Risks

- Risk 1. The upstream skill may do the wrong thing to an existing document. Upstream issue #29, open, filed 2026-09-06, reports that asking the skill to rewrite an existing document produced sentence splitting and formatting removal rather than the substantive cleanup the reporter wanted. The author agreed that removing those constructions is the goal and asked for examples. The thread was unresolved as of 2026-09-08. This is one unconfirmed report and not a measurement, and it is also the only published evidence about the exact path this plan takes, which is rewriting existing documents rather than authoring new ones.
  - Why it lands harder here than it would elsewhere. The two symptoms the reporter described are the only outputs this pass has available. Measured filler across the four targets is two instances in total, so substantive cleanup is not on the table, and punctuation normalisation plus sentence shortening is the entire job. A successful run and the reported failure therefore produce diffs that look alike at first glance. What separates them is whether the document structure survived intact and whether the shortening stopped at a readable length.
  - Mitigation. Success Criteria splits the necessary condition from the sufficient one. U1 records a structure and sentence baseline before any edit is made. The Verification Contract carries a discriminator table that a reviewer reads in one pass.
  - Escalation. If `CONCEPTS.md` cannot reach zero em-dashes without its sentence count rising more than 15 percent, stop and report rather than accepting the trade. That file carries the highest mean sentence length of the four at 25.7 words, so it is the most likely place for the failure to appear first.
- Risk 2. An editor working through a long file drifts from repair into rewriting. The `CONCEPTS.md` pass is 3446 words and 33 findings, which is long enough for drift. Mitigation: the structure inventory and the filler count both act as tripwires, because a rewrite moves them and a repair does not.

### Verification Constraints

No target file is chezmoi-managed. `.chezmoiroot` is `home`, and none of `README.md`, `CONCEPTS.md`, `CLAUDE.md`, or `docs/agent-verification.md` lives under `home/`. Under `docs/agent-verification.md` this change therefore falls into none of the three risk classes that require a chezmoi verdict. `make test-local` and `make test-ubuntu` prove nothing here and must not be run as evidence for it. `make lint` runs shellcheck and no shell script changes, so it is unaffected.

This is a deliberate consequence of KTD3 and the `home/**` exclusion. The moment a managed path enters scope, the risk class changes and a `make test-ubuntu` verdict becomes mandatory.

---

## Implementation Units

### U1. Pin the rule catalog and freeze the target list

- Goal: establish the mechanism CHECK mode requires, and produce a frozen, verified list of what the pass will touch.
- Requirements: R1, R2, R3, R6, R7
- Dependencies: none
- Files:
  - `home/private_dot_agents/skills/<name>/references/rule-catalog.md` (read only, vendored by the prerequisite plan)
- Approach:
  1. Confirm the vendored catalogue exists in the checkout and holds the 53 rules across 9 sections. If it is absent, stop: the prerequisite plan has not landed and this pass has no fallback, per KTD1.
  2. Write the frozen target list: `README.md` and `CONCEPTS.md` for edit, `CLAUDE.md` and `docs/agent-verification.md` for report.
  3. Run a Cyrillic scan across the four targets and record the per-file count. All four are expected to return zero. A non-zero count on any of them moves that file out of scope under R7 rather than into a judgment call.
  4. Record the full baseline per target, not only the punctuation counts. Capture em-dash, semicolon and contraction counts with fenced blocks and inline code spans removed, plus sentence count, mean sentence length, filler count, and the structure inventory of headings, list items, table rows, fenced blocks and links taken from the raw file. Risk 1 makes the last two groups load-bearing rather than informational, because they are what tells a repair apart from the reported failure.
  5. If the `ste_lint.py` vendoring plan has already landed, stop and re-scope: the mechanical counts become that linter's output and this pass narrows to judgment rules only.
- Patterns to follow: the measurement discipline in `CLAUDE.md` under "Working with code", which requires measuring a corpus rather than eyeballing it.
- Test expectation: none. This unit produces a scratch artifact and a set of counts, and changes no committed behavior. See KTD5.
- Verification: the vendored catalogue is readable from the checkout and contains numbered rules, the frozen list names exactly four files, and every baseline group in step 4 exists for each of them. A baseline missing its structure inventory or sentence count does not satisfy this unit, because U2 cannot then be judged against Risk 1.

### U2. Cosmetic prose pass on the two non-behavior-bearing documents

- Goal: `README.md` and `CONCEPTS.md` follow the repository's sentence rules.
- Requirements: R2, R4, R8
- Dependencies: U1
- Files:
  - `README.md`
  - `CONCEPTS.md`
- Approach:
  1. Run CHECK against each file, reporting each violation as rule number, offending text, and rewrite.
  2. Apply the rewrites. Judgment is allowed across all 53 rules here, bounded by R8.
  3. Leave every code span, command, path, identifier, product name, and quoted string untouched. `CONCEPTS.md` is a vocabulary document, so its defined terms are identifiers and must survive verbatim even where a rule would prefer a different word.
  4. Re-run every baseline group from U1. Confirm the punctuation counts reach zero outside protected spans, and confirm the structure inventory is byte-for-byte identical to the baseline. Splitting a sentence is allowed. Dropping a heading, a list item, a link or a fenced block is not, and neither is merging two list items into prose.
  5. Read the result once as a reader rather than as an editor. If the file now reads as a sequence of short disconnected statements, the pass over-split it and the fix is to rejoin, not to ship.
- Patterns to follow: the "Cut words, not correctness" and "Keep the grammar plain" sections of `home/.chezmoitemplates/writing-style.md`.
- Test expectation: none. Prose style has no runtime behavior and no consumer whose failure a test could observe. A no-em-dash assertion would be a source-shape assertion of absence taking its expected value from this same patch. See KTD5.
- Verification: `git diff` shows prose changes only. No line in the diff changes a defined term in `CONCEPTS.md`, a command, or a path. The Cyrillic count per file is unchanged from U1. The structure inventory is identical to the U1 baseline, the sentence count is within 15 percent of it, and the shortest new sentence is about five words or longer. Read the discriminator table in the Verification Contract before signing this unit off.

### U3. Report-only CHECK on the two behavior-bearing documents

- Goal: the owner can see exactly how far `CLAUDE.md` and `docs/agent-verification.md` sit from the style, and can judge each finding on its merits, without any edit having happened. The report is the deliverable of this unit and of the pass for these two files. Editing them is a separate follow-up in U4 that runs only on approved findings.
- Requirements: R2, R5, R9, R10
- Dependencies: U1
- Files:
  - `CLAUDE.md` (read only in this unit)
  - `docs/agent-verification.md` (read only in this unit)
- Approach:
  1. Run CHECK against both files and produce one report. Deliver it to the owner. Do not write it into `docs/` as a committed artifact, because it is a working list and not a durable record.
  2. Classify every finding into one of three buckets: mechanically safe, meaning-affecting, or protected. Mechanically safe covers em-dash, semicolon, contraction, and simple-tense repair. Meaning-affecting covers every modal change, every active-voice conversion inside an `<important if=...>` block, and every vocabulary substitution, all of which are forbidden here under R9 and KTD6 and are reported only so the owner can see them. Protected covers table cells that gate a command choice, risk-class definitions, and any literal string another tool consumes verbatim.
  3. Render each finding with enough surrounding text for the owner to judge whether the wording is load-bearing. A bare count is not a finding and a bare line number does not let anyone approve or reject one. Each finding carries:
     - a stable identifier `F<N>`, so the owner can approve or reject by identifier rather than by description
     - the file path and the line number
     - the violated rule named in words with its number in parentheses, quoted from the vendored catalogue, matching the convention the document-style skill plan sets
     - the bucket from step 2
     - the context, quoted verbatim: the full sentence carrying the span, plus the sentence before and after it. When the span sits inside an `<important if=...>` block, quote the whole condition and the whole bullet it sits in. When the span sits in a table row, quote the header row and the entire row.
     - the proposed rewrite, written as a complete replacement for the quoted span rather than as a fragment or a diff
     - a load-bearing note naming the structure the span sits in and what reads it
     - an approval slot whose default is reject
  4. State the bucket counts up front so the owner can judge the size of the decision before reading. Measured expectation from the current tree: `CLAUDE.md` carries 44 em-dash and semicolon occurrences, of which 24 sit inside `<important if=...>` blocks, 2 sit in table rows, and 18 sit in plain prose. `docs/agent-verification.md` carries 5, of which 2 sit inside the Deployment-sensitive risk-class row and 3 sit in plain prose. More than half of the `CLAUDE.md` findings therefore sit inside a load-bearing structure, which is the reason the context requirement in step 3 exists.
  5. Ask for approval one finding at a time. Do not proceed to U4 without it, and do not batch approval across buckets.
- Patterns to follow: the decision-request shape in `home/.chezmoitemplates/writing-style.md` under "Ask for one decision at a time".
- Test expectation: none. This unit changes no file. See KTD5.
- Verification: `git status` shows no modification to either file. The report exists, and every finding carries all eight fields from step 3, including quoted context wide enough to judge the wording without opening the source file. Every finding is classified into one of the three buckets. The unit is complete when the report is delivered, whether or not the owner approves anything.

### U4. Apply the approved subset to the behavior-bearing documents

- Goal: the approved mechanical findings land in `CLAUDE.md` and `docs/agent-verification.md` with no instruction changing force. This unit is a gated follow-up to the U3 report and not part of the pass proper. It has no content of its own until the owner approves specific findings, and an empty approval set is a normal and complete outcome.
- Requirements: R5, R8, R9, R10
- Dependencies: U3, and explicit user approval of specific findings. This unit does not run on its own.
- Files:
  - `CLAUDE.md`
  - `docs/agent-verification.md`
- Approach:
  1. Apply only findings the user approved, and only from the mechanically safe bucket, per KTD6.
  2. Leave the risk-class table in `docs/agent-verification.md` alone. A measurement of the current tree corrects an earlier assumption in this plan: two of that file's five semicolons sit inside the Deployment-sensitive row itself, not in the prose around it. They separate three alternative trigger conditions that a reader takes as alternatives. Rewriting them into separate sentences either breaks the table cell or risks reading a set of alternatives as a sequence, which would change which diffs require a `make test-ubuntu` verdict. Those two are protected findings and are never eligible whatever the approval says. The other three sit in prose around the table and are ordinary mechanical findings.
  3. Re-read each `<important if=...>` condition after editing its block and confirm the trigger still describes the same situation.
  4. Confirm that no "should" became a "must" and that no advisory sentence became mandatory.
- Execution note: verify by reading the rendered instruction rather than the diff alone. A diff shows the character that changed and not the force that changed with it.
- Test expectation: none. The change is prose inside instruction documents. The property that matters, that an instruction's force is unchanged, is a semantic judgment with no independent oracle available to a test in this repository. See KTD5.
- Verification: `git diff` contains no modal change, no `<important if=...>` condition change, and no table-cell change. A reviewer reading the two files can state what each instruction requires and match it to the pre-edit text.

---

## Verification Contract

| Check | Applies | Why |
|---|---|---|
| Manual `git diff` review of every edited file | U2, U4 | The only meaningful gate. The property under test is that meaning did not change, which a human reads and a test cannot assert. |
| Cyrillic scan per edited file, before and after | U2, U4 | Confirms no quoted non-English text was touched. Enforces R7 and KTD4. |
| Em-dash, semicolon, and contraction counts, before and after | U2 | Confirms the cosmetic pass reached its target. An outcome check for the author, not a committed test. |
| Structure inventory, before and after, required identical | U2 | Headings, list items, table rows, fenced blocks and links. This is the check that catches the formatting-removal half of Risk 1. |
| Sentence count and mean sentence length, before and after | U2 | Catches the sentence-splitting half of Risk 1. A rise above 15 percent fails the unit. |
| Report field completeness, all eight fields per finding | U3 | The report is the deliverable for the two behaviour-bearing files, so an incomplete finding is an incomplete unit. |
| `make lint` | not applicable | Runs shellcheck. No shell script changes. |
| `make test-local` | must not be run as evidence | No managed path changes, so it proves nothing about this diff. See Verification Constraints. |
| `make test-ubuntu` | must not be run as evidence | Same reason. Running it would manufacture confidence rather than supply it. |
| Pull-request continuous integration | on publish | The standard backstop. Both the Ubuntu and macOS jobs must pass before merge, per `docs/agent-verification.md`. |

### Telling a real improvement from the Risk 1 failure

Punctuation counts cannot distinguish the two outcomes, because both drive them to zero. Filler counts cannot distinguish them either, because there is almost no filler to begin with. Only the middle three rows carry the verdict.

| Signal | Real repair | The Risk 1 failure |
|---|---|---|
| Em-dash and semicolon counts | fall to zero | fall to zero |
| Structure inventory | identical to baseline | falls, as headings, lists or links are dropped |
| Sentence count | stable, at most 15 percent higher | rises sharply |
| Shortest sentence the pass created | about five words or longer | two or three words, telegraph style |
| Filler count | unchanged, already near zero | unchanged, already near zero |

A reviewer who checks only the first row learns nothing, and that is the trap the upstream reporter fell into.

No new test is added by any unit. The oracle line required before a first test edit cannot be completed for prose style, and KTD5 records why in full.

---

## Definition of Done

Global:

- `README.md` and `CONCEPTS.md` carry no em-dash and no semicolon outside code spans, quoted text, and protected literals, and their structure inventories are identical to the U1 baseline.
- The U3 report was delivered and the user made a decision on it, including a decision to decline everything.
- No file under `home/` changed, so the change never entered the deployment-sensitive risk class.
- No file with a `date:` field or a dated filename changed.
- No test was added.
- Q1, Q2 and Q4 were settled before the pass started. Q3 may remain open, because it is deferred.

Per unit:

- U1: the catalog is pinned with its fetch date, the target list is frozen at four files, and baseline counts exist.
- U2: both cosmetic files are edited and their diffs contain prose changes only.
- U3: the report exists, every finding is classified and carries all eight fields including quoted context, and no file changed. This unit is done when the report is delivered, independently of what the owner then approves.
- U4: only approved mechanical findings landed, and no instruction changed force. If the user declined every finding, U4 is done with an empty diff, which is a successful outcome and not a skipped unit.
