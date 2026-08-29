# Long-running work

A long-running process remains owned until it reaches an observed terminal state or control is explicitly transferred. Supervision protects useful work; an arbitrary deadline does not.

This file re-anchors the Environment rules in `~/.claude/CLAUDE.md` at the moment a process is launched, and adds what a tier-1 bullet cannot carry: the ordered supervision contract, and the failure patterns that keep a wait looking healthy after the work is already dead.

## Supervision contract

1. **Define completion and progress before launch.** Name the terminal success and failure signals, how the exit status will be recovered, and what observable change distinguishes progress from a live but blocked process.
2. **Choose an observation cadence and the mechanism that carries it past this turn.** Set the next check from the process's expected progress rate and cost of failure. Name what will actually wake that check: a backgrounded task whose completion re-invokes the agent, a durable monitor armed on the log or state file, a scheduled wake-up, or a pane the user and the agent both read. A cadence with no mechanism behind it is an intention, not a plan.
3. **Verify the launch path.** Immediately confirm that the intended process started, output or state is observable, and the monitor can see its first event. Check whether the work depends on the launching wrapper, terminal, or parent remaining alive.
4. **Inspect state at every checkpoint.** Check both liveness and progress: output age or growth, process tree, resource activity, child state, and the expected completion signal. A live PID alone is not evidence of progress; quiet output alone is not evidence of failure.
5. **Treat unexplained stasis as an incident.** When expected progress stops, diagnose promptly instead of extending the wait. Establish whether the process is computing, blocked, orphaned, waiting for input or EOF, observing the wrong output, or already dead before deciding what to do.
6. **Separate a chosen deadline from an imposed one.** A deadline the agent picks needs a real maximum duration, a diagnostic purpose, or a safely restartable operation whose lost progress is acceptable — and it never serves as the sole supervision mechanism. A deadline the environment imposes, such as a tool's maximum runtime or a silence limit that kills the worker, is not negotiable: decide before launch what its expiry will mean and how the work survives it. Never restart automatically without identifying the previous run's state.
7. **Keep ownership explicit.** The launching agent follows the work through success, failure, cancellation, or an explicit handoff that names the process, current evidence, next check, and wake-up condition. Ending a turn on "still waiting" is honest only when a named mechanism from rule 2 will resume it; with no such mechanism, the turn has silently dropped the process.
8. **Escalate when the state cannot be determined.** Diagnosis that returns no answer is itself terminal for the agent's own supervision: rule 5 forbids extending the wait, rule 6 forbids an unjustified kill, so the decision belongs to the user. Report the process, what was observed, which checks were already run, and the live options — keep waiting, terminate, restart. Never settle an undiagnosable stall by guessing.

## Known failure patterns

- **Parent-dependent work:** wrappers, remote sessions, and ephemeral containers may terminate their children during cleanup. If the launcher disappears, verify the actual workload rather than assuming it survived. Persist the workload's terminal status separately from the launcher's process state when practical.
- **Inherited streams and handles:** a descendant can keep stdout, stderr, a pipe, or another file descriptor open after the apparent work finishes. The caller then waits indefinitely for EOF despite complete-looking output. Inspect descendants and inherited handles when output is complete but the runner never returns.
- **Misleading completion capture:** pipeline status syntax is not portable — bash exposes `${PIPESTATUS[0]}` indexed from zero, zsh exposes `${pipestatus[1]}` indexed from one, and the wrong shell's syntax reports a silent success. Capture the intended command's status with the active shell's semantics, persist it beside the output when monitoring asynchronously, and verify that the completion record was actually written.

These patterns are diagnostic prompts, not automatic verdicts. Use observed state to choose whether to continue, repair, terminate, restart, or escalate.
