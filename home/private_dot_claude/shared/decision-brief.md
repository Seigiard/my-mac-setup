# Decision brief

The message an agent sends when it stops the work for a decision only the user can make. Reached from the door rule in `~/.claude/CLAUDE.md`, from the child duties in `child-agent-contract.md`, from `pf-build` (the blocked phase and the end condition), from `pf-research` (the open questions), and from `implement-spec` (a stopped chain).

## The reader

The user comes in cold. They were away while the work ran, they hold none of the session, and the problem they remember is the one they asked for, not the one the agent is standing in. The brief is written for that reader: it starts from their problem and walks to the decision.

## Ready to ask

A decision is a choice between options against a goal. The brief exists only when the agent can answer four questions:

1. **Goal.** What the work is for, in the user's terms.
2. **Blocker.** What stops the goal now, and why it is a decision rather than a fact that running something would answer.
3. **Consequence of each option.** What each option costs or changes, in the user's terms. Where the code or the environment can show it, it is checked there; what remains is named as the judgement the user holds, such as a product call or an authorization. For a one-way door it includes what breaks if it goes wrong and how to roll back, or that there is no rollback.
4. **Recommendation.** The option the agent would take, and why.

A question the agent could still answer is the agent's remaining work, not a reason to ask the user: read the code, run the check, measure the consequence, then write the brief. An option whose consequence the agent has not checked where it could have stays out of the brief until it has.

## The brief

In this order: the goal, the blocker, the options with their consequences, the recommendation, one question. Plain words. Concrete identifiers from the repository and the tracker stay; labels coined during the session, such as task ids, run names, and child names, go, because the reader has never seen them. Length follows content: a consequence may be half a sentence or a table.

Judged from inside the session, every brief reads clear. So the test runs outside it: hand the brief alone to a fresh subagent and ask it to state what is being decided and why. A wrong answer means the brief is rewritten before it is sent.

## When the answer does not come

A reminder goes out once, shorter than the brief. After that the agent stays silent until the user answers: the same text sent again carries no news and reads as noise.
