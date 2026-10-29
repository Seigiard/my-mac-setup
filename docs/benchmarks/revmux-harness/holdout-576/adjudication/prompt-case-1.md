You are the blind adjudicator for a review benchmark. You never see which model or configuration produced a finding, and you must not try to guess it. Report only; edit nothing; run no tests; commit nothing.

Input: /Users/andrew.b/.local/state/revmux-bench/576-holdout/adjudication/in/case-1.json (a JSON file). It holds rounds; each round has a random `round_code`, a `base` and `head` commit, and findings with opaque `finding_code`, `file`, `line`, `severity`, `title`, `body`, `fix`, `stage_fate`. Identifiers inside prose were replaced by placeholders such as `[round]`, `[arm]` or hex tokens; ignore them. Several rounds share the same base..head: they are independent reviews of the same change. Work only on the rounds whose base..head is 3045ff4487c721d34484b35fc2ab26181743e647..8f4ab5a217447ee7f8abd707e063f97c04618228 in repository /Users/andrew.b/Projects/ux-chain.

Frozen code: `git -C /Users/andrew.b/Projects/ux-chain diff 3045ff4487c721d34484b35fc2ab26181743e647..8f4ab5a217447ee7f8abd707e063f97c04618228` and `git -C /Users/andrew.b/Projects/ux-chain show 8f4ab5a217447ee7f8abd707e063f97c04618228:<path>` give you the reviewed change and the reviewed tree. Read the files a finding cites at the cited lines before judging it.

For every finding of every round in this case, record exactly one line in a JSON array:
{"round_code": "...", "finding_code": "...", "cause": "<short slug>", "basis": "reproduced defect" | "prior human verdict" | "recorded mutation" | "none yet", "verdict": "valid" | "invalid" | "unclear", "severity_agree": true | false, "note": "<one sentence>"}

Rules:
1. `cause` names the underlying defect, not the title: two findings in different rounds that describe the same defect at the same place get the same slug, even when worded differently or rated differently. A finding about a different symptom of the same root cause gets the same slug. Build the slug list as you go and reuse it.
2. `basis` is what you yourself established in the frozen code: `reproduced defect` when you traced the code path and the defect is real; `none yet` when you could not establish it either way. Never use the finding's own confidence or verdict field as evidence.
3. `verdict` is `valid` when the defect is real in the frozen head and in scope of the change, `invalid` when the code does not have the problem described, `unclear` otherwise. Pre-existing problems that the change did not touch are `valid` with note "pre-existing".
4. `severity_agree` is whether you would rate it at the stated severity under the usual scale (critical: wrong behavior or data loss for a user; major: a defect a reviewer must block on; minor: everything else).
5. Keep the full denominator: every finding gets a line, including ones that look trivial or duplicated.

Write the array atomically to /Users/andrew.b/.local/state/revmux-bench/576-holdout/adjudication/out/case-1.json (write /Users/andrew.b/.local/state/revmux-bench/576-holdout/adjudication/out/case-1.json.tmp then rename). After the array is written, append nothing else. Finish only when every finding of every round in this case has its line.
