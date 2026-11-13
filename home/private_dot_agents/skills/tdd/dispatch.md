# Dispatch

Write the child's prompt to `<role>-<n>.prompt.md`. It carries pointers only, never pasted history:

```text
Role: <test writer | implementer>, attempt <n>.
Mode: <prepare | calibrate>   <- test writer only
Rows: <every plan row | the rows named after a failed replay, with their replay-<m>/ logs>   <- calibrate only
Read your brief first and follow it: <absolute path to test-writer.md or implementer.md>.
Ticket: <run-dir>/ticket.md (its Verdicts section lists earlier attempts and why they were rejected).
Lock: <run-dir>/lock.json   <- when a lock exists: implementer, or a test writer that re-locks or extends it
Targeted fix: <diagnosis ID in Verdicts>   <- targeted fix only
Exclusive file scope: <allowed test paths and fixtures | planned temporary production paths | the whole checkout>   <- prepare | calibrate | implementer
Report: <run-dir>/<role>-<n>.report.md; publish it by the atomic-write rule in <absolute path to run-directory.md>.
Work in <checkout> on branch <branch>. Calibration state: <calibration_sha>   <- calibrate only
```

Every child runs on OpenCode, its tier mapped through the OpenCode column of `~/.claude/shared/model-tiers.md`. Choose the launch mode in this order:

When `HC_TERMINAL_ID` is set, use hc mode: run `hc-run --cwd <checkout> implementer-<tier> "$(cat <prompt>)"`, with `+` spelled `-plus`; the test writer uses the same read-write opencode role and its prompt carries the role. Record the printed `<address> <alias>`. Wait inside a turn with `hc wait --json --timeout S <address>`; parent duties and the cleanup guard are in `~/.claude/shared/hc-agent-contract.md`.

If `hc-run` exits 3, its address is only a recovery handle: use the printed `task not sent` or `task sent but not started` diagnostic, then follow the `hc` skill's exit-3 rule and inspect `hc get` and the consumed screen before any send. Do not treat the child as started, resend from an unexposed `first_message.sent` receipt, or claim that `enter` was tried unless the screen showed a draft without a blocking dialog. Preserve working and blocked children; defer permission decisions to the person.

1. `opencode` is on `PATH`: run the following as a background process that re-invokes you on exit (in Claude Code, the Bash tool's `run_in_background`). The stdin redirect prevents `opencode run` from waiting for EOF. `~/.claude/shared/long-running-work.md` owns its supervision.

   ```bash
   (
     cd <checkout> || exit
     exec opencode run -m <model>#<variant of tier> --standalone --auto --format json "$(cat <prompt>)"
   ) < /dev/null > <run-dir>/<role>-<n>.jsonl 2>&1
   ```

   Keep the process exit status and the JSONL events separate; an `error` event or a log without a final answer is incomplete work.
2. Otherwise no child can start. Stop.

**Resuming a child** for a handoff gap keeps its session, tier, and attempt number, and counts as one turn. In headless mode: the same subshell command with `--session <id>` added and `'<the missing items>'` as the prompt, appending to `<run-dir>/<role>-<n>-resume.jsonl`, where the id is the `sessionID` in the attempt's JSONL log. Every resumed turn of the attempt appends to that file in order.

In hc mode, resume a child with `hc send <address> '<the missing items>'`; its session stays in its terminal.
