# Long-running work

A long-running process remains owned until it reaches an observed terminal state or control is explicitly transferred. Supervision protects useful work; an arbitrary deadline does not.

Reached from the long-running-process block in `~/.claude/CLAUDE.md`.

## When this applies

Apply the launch form below to any command whose duration you cannot bound under the tool's timeout. Apply the contract when the process runs for more than a few minutes, or cannot be restarted safely, and nothing but you watches it. If the tool already supervises itself — it reports progress, detects stalls, and returns a terminal status you can read — rely on that and skip the rest of this file.

## Launch form

Pick the launch form from where the result goes; when both apply, evidence wins:

- **Result read in this session** (a test suite, a build, a one-off script): launch it in the background with the client's own shell and let the completion notification wake you. In Claude Code that is the Bash tool's `run_in_background`; in OpenCode it is `shell` with `background: true`. A foreground call with a timeout is for a command you have seen finish inside that timeout.
- **Result that is evidence**, read later or by someone else, or a workload that must outlive this session: launch `herdr-run <label> --wait -- <command>` in the background form above, with a label unique to this checkout, and read the result with `herdr-run verdict <label>`. Its verdict persists under `~/.cache/herdr-run`, and while `--wait` watches, an idle log prints the process tree.

A tool timeout that ends a run is a launch-form error, not a verdict. Identify the previous run's state and its surviving children first (rule 6): recover a finished result, keep supervising work that is still useful, and relaunch only a command whose replay is safe, in a background form above, with its leftovers stopped, such as a dev server still holding its port.

## Supervision contract

1. **Define completion and progress before launch.** Name the terminal success and failure signals, how the exit status will be recovered, and what observable change distinguishes progress from a live but blocked process.
2. **Choose an observation cadence and the mechanism that carries it past this turn.** Set the next check from the process's expected progress rate and cost of failure. Name what will actually wake that check: the launch form's completion notification, a durable monitor armed on the log or state file, or a scheduled wake-up. Use a visible pane only when the user asks to watch the process or a project rule requires one. A cadence with no mechanism behind it is an intention, not a plan.
3. **Verify the launch path.** Immediately confirm that the intended process started, output or state is observable, and the monitor can see its first event. Check whether the work depends on the launching wrapper, terminal, or parent remaining alive.
4. **Inspect state at every checkpoint.** Check both liveness and progress: output age or growth, process tree, resource activity, child state, and the expected completion signal. A live PID alone is not evidence of progress; quiet output alone is not evidence of failure.
5. **Treat unexplained stasis as an incident.** When expected progress stops, diagnose promptly instead of extending the wait. Establish whether the process is computing, blocked, orphaned, waiting for input or EOF, observing the wrong output, or already dead before deciding what to do.
6. **Separate a chosen deadline from an imposed one.** A deadline the agent picks needs a real maximum duration, a diagnostic purpose, or a safely restartable operation whose lost progress is acceptable — and it never serves as the sole supervision mechanism. A deadline the environment imposes, such as a tool's maximum runtime or a silence limit that kills the worker, is not negotiable: decide before launch what its expiry will mean and how the work survives it.
7. **Keep ownership explicit.** The launching agent follows the work through success, failure, cancellation, or an explicit handoff that names the process, current evidence, next check, and wake-up condition. Ending a turn on "still waiting" is honest only when a named mechanism from rule 2 will resume it; with no such mechanism, the turn has silently dropped the process.
8. **Escalate when the state cannot be determined.** Diagnosis that returns no answer is itself terminal for the agent's own supervision: rule 5 forbids extending the wait, rule 6 forbids an unjustified kill, so the decision belongs to the user. Report the process, what was observed, which checks were already run, and the live options — keep waiting, terminate, restart.

## Known failure patterns

- **Parent-dependent work:** wrappers, remote sessions, and ephemeral containers may terminate their children during cleanup. If the launcher disappears, verify the actual workload rather than assuming it survived. Persist the workload's terminal status separately from the launcher's process state when practical.
- **Inherited streams and handles:** a descendant can keep stdout, stderr, a pipe, or another file descriptor open after the apparent work finishes. The caller then waits indefinitely for EOF despite complete-looking output. Inspect descendants and inherited handles when output is complete but the runner never returns.
- **Misleading completion capture:** pipeline status syntax is not portable — bash exposes `${PIPESTATUS[0]}` indexed from zero, zsh exposes `${pipestatus[1]}` indexed from one, and the wrong shell's syntax reports a silent success. Capture the intended command's status with the active shell's semantics, persist it beside the output when monitoring asynchronously, and verify that the completion record was actually written.

These patterns are diagnostic prompts, not automatic verdicts. Use observed state to choose whether to continue, repair, terminate, restart, or escalate.
