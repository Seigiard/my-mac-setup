# Dispatch

How the tdd orchestrator starts, resumes, and reaps a child, reached from [Dispatch](SKILL.md#dispatch) in SKILL.md.

Write the child's prompt to `<role>-<n>.prompt.md`. It carries pointers only, never pasted history:

```text
Role: <test writer | implementer>, attempt <n>.
Mode: <prepare | calibrate>   <- test writer only
Read your brief first and follow it: <absolute path to test-writer.md or implementer.md>.
Ticket: <run-dir>/ticket.md (its Verdicts section lists earlier attempts and why they were rejected).
Lock: <run-dir>/lock.json   <- when a lock exists: implementer, or a test writer that re-locks or extends it
Targeted fix: <diagnosis ID in Verdicts>   <- targeted fix only
Exclusive file scope: <allowed test paths and fixtures | planned temporary production paths | the whole checkout>   <- prepare | calibrate | implementer
Report: <run-dir>/<role>-<n>.report.md; publish it by the atomic-write rule in <absolute path to run-directory.md>.
Work in <checkout> on branch <branch>. Commit prepare and implementation work. Calibration restores <calibration_sha> without commits. Do not push.
```

Choose the launch mode in this order:

When `HC_TERMINAL_ID` is set, use hc mode: run `hc-run --cwd <checkout> implementer-<tier> "$(cat <prompt>)"`. Map the tdd tier to `implementer-low`, `implementer-low-plus`, `implementer-medium`, `implementer-high`, or `implementer-high-plus`; the test writer uses the same read-write opencode role and its prompt carries the role. Record the printed `<address> <alias>`. The child wakes you through the core's notes (`<hc>… is blocked/exited…</hc>`) and `hc send`; wait inside a turn with `hc wait --json --timeout S <address>`. The parent duties and cleanup guard are in `~/.claude/shared/hc-agent-contract.md`.

If `hc-run` exits 3 because the task was not delivered, follow the exit-3 recovery rule in the `hc` skill.

1. `HERDR_ENV=1` and `HERDR_CHILD_PARENT_PANE` is unset: start a visible tab with `herdr-child start --kind opencode --posture rw --model <model> --effort <effort of tier> --cwd <checkout> --prompt-file <prompt> --detach`. Tabs avoid the narrow-pane OpenCode hang. Follow the parent duties in `~/.claude/shared/child-agent-contract.md`; the supervision marker wakes you. Answer a child's `herdr-child ask` from `ticket.md`; pass it to the user only when it needs a product decision. A herdr child goes straight to mode 2 because `herdr-child start` refuses to run from a child pane.
2. `opencode` is on `PATH`: run the following as a background process that re-invokes you on exit (in Claude Code, the Bash tool's `run_in_background`). The stdin redirect prevents `opencode run` from waiting for EOF. `~/.claude/shared/long-running-work.md` owns its supervision.

   ```bash
   (
     cd <checkout> || exit
     exec opencode run -m <model>#<variant of tier> --standalone --auto --format json "$(cat <prompt>)"
   ) < /dev/null > <run-dir>/<role>-<n>.jsonl 2>&1
   ```

   Keep the process exit status and the JSONL events separate; an `error` event or a log without a final answer is incomplete work.
3. Otherwise no child can start. Stop.

**Resuming a child** for a handoff gap keeps its session, tier, and attempt number, and counts as one turn. In herdr mode: `herdr-child prompt --to <name> --pane <pane-id> --detach '<the missing items>'`. In headless mode: the same subshell command with `--session <id>` added and `'<the missing items>'` as the prompt, appending to `<run-dir>/<role>-<n>-resume.jsonl`, where the id is the `sessionID` in the attempt's JSONL log. Every resumed turn of the attempt appends to that file in order.

In hc mode, resume a child with `hc send <address> '<the missing items>'`; its session stays in its terminal. Wait with `hc wait --json --timeout S <address>`.

In hc mode, reap a child only after `hc get <address>` shows that its status is not `working` or `blocked`: run `hc kill <address>` and then `hc rm <address>`.

The child's answer is its report file; its tool output and logs are the evidence the report cites. In herdr mode, reap each child with `herdr-child reap` per the `herdr` skill's lifecycle rule. In headless mode, confirm the process has exited before the next phase starts.
