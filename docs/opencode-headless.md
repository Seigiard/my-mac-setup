# Durable OpenCode headless turns

`~/.local/bin/opencode-headless.py` is a Python 3 standard-library helper for
`pf-spec` frontier reviews and `tdd` headless children. Chezmoi installs it from
`home/dot_local/bin/executable_opencode-headless.py`. Python 3.9 or later, Git
for review worktrees, and OpenCode on `PATH` are the runtime dependencies.
The helper detects the CLI major with `--version`. The calibrated versions are
V1 `1.19.0` and V2 `2.0.28`; other major versions are rejected.

## Commands

```sh
opencode-headless.py launch --run "$new_run" --cwd "$checkout" \
  --model "$model" --prompt-file "$prompt"
opencode-headless.py resume --run "$new_run" --prompt-file "$next_prompt"
opencode-headless.py cleanup --run "$new_run"
```

`launch` requires a new artifact directory with an existing parent. `--auto`
enables OpenCode's permission approval for implementation children. Repeated
`-f` options attach files; paths resolve from the invoking shell. Prompt and
model are passed as argv values without a shell. The child receives closed
stdin and a `PWD` that matches its process cwd.

V2 runs with `--standalone`, whose private server has a stdin ownership lease.
V1 uses its default in-process server. The helper never attaches to a service or
an external server. It saves the binary version and storage environment paths;
resume uses those paths and rejects a changed CLI version.

For a frontier review, add `--review-ref "$committed_ref"`. The helper creates a
detached worktree under the artifact directory. Put that directory outside the
epic checkout. It records the epic's full porcelain status, including individual
untracked files, and compares each completed turn against that original baseline.
This detects persistent non-ignored changes only. The worktree is disposable,
not a sandbox; refs and Git configuration remain shared. The calling skill owns
the cooperative review prompt and the finding decisions.

`resume` reads the saved cwd, model, permission mode, and native session. It first
exports that session through `session export --standalone` on V2 or `export` on
V1, with the saved storage environment. The export must contain the expected ID,
checkout, and nonempty history. V2 `run --session` alone is insufficient: it can
create a new session with the requested ID. The export is an existence check,
not a query of another server's active work. No private-server/shared-session
status inference is made.

A missing session record can be recovered from JSONL only after the earlier
turn's owned lifecycle completed. New attachments belong to the resumed turn.
The helper never forks the session or silently starts a replacement session.

## Evidence and completion

Each turn has its own `turn-NNNN/` directory:

- `request.json` and `prompt.md`: the exact launch inputs.
- `events.jsonl` and `stderr.log`: separate raw streams.
- `process.json`: the child process group, used to reject active cleanup/resume.
- `status.json`: process exit, transport classification, session, model, and
  epic comparison result. It starts as `incomplete` with unknown exit status and
  `quiescent: false`.
- `session.json` and `answer.txt`: extracted identity and model text.
- `session-check.*`: resume's export command, output, stderr, and exit status.

V2 text suffixes are joined within the same message/part. Reconciliation's
projected IDs use `prt_<message-without-msg_>_text-<ordinal>` and map to the
message's text ordinal. Separators occur only between
parts or messages. V1 full-part updates replace the prior value for that part.

The command prints the final status as JSON. Exit `0` with `transport-ok` means
the process exited `0`, JSONL parsed without error events, one expected session
was present, text was nonempty, and the epic comparison passed when applicable.
It does not accept the task or the findings. `failure` and `incomplete` return
`1`. Argument syntax errors return `2`. Setup errors go to stderr as JSON.
Missing terminal artifacts after a wrapper crash mean incomplete work, even if
the remaining log contains text. Text or an absent CLI PID does not establish
that the native server or its tool work stopped.

The helper is synchronous. It adds no deadline, watcher, or retry loop. The
caller owns supervision under the shared long-running-work contract. SIGINT,
SIGTERM, and SIGHUP request SIGINT on the CLI once, so V2 can call native
`session.interrupt`. Repeated forwarding is suppressed: V2's second SIGINT
calls `process.exit(130)` before teardown. The helper retains an incomplete verdict. The private
server uses a separate process group; signalling only the CLI group is not a
server-stop mechanism.

An exclusive lock and recorded process groups block active resume and cleanup.
The helper records `quiescent: true` after the owned CLI returns normally,
including provider failure (`1`) and handled interruption (`130`). The pinned V2
entrypoint closes `Effect.scoped` before exiting with `process.exitCode`.
Lifecycle completion is separate from transport success: those failed or
interrupted turns keep their verdicts and permit same-session resume or cleanup.
An export preflight that returns an error keeps diagnostics but sends no prompt;
it also permits retry or cleanup. A spawn failure starts no native work.

Hard-killed processes, a killed wrapper without a saved exit, and legacy unowned
runs still fail closed, even after their process group disappears. The caller
must report operator recovery instead of inferring that descendants stopped or
starting another private server as proof. There is no automatic hard-kill
recovery override or management of arbitrary detached daemons a task starts.

Call `cleanup` after all continuations settle or after explicit abandonment;
abandonment does not waive the native-stop check.
It removes the disposable worktree, verifies its path and Git registration are
absent, then removes `state.json`. Failure returns nonzero and retains recovery
state. A locked Git worktree must be unlocked before retry. Direct mode retains
the checkout. Both modes retain logs and the lock file; a completed run path
cannot be reused for a new launch. Cleanup does not delete OpenCode's native
session database. Logs and prompts have the same sensitivity as their inputs.

## Focused verification

```sh
python3 -B -m unittest discover -s tests -p 'test_opencode_headless.py' -v
```

The suite uses real subprocesses and Git worktrees. Its synthetic OpenCode
transport and pinned upstream source calibration are described in
[`tests/fixtures/opencode-headless/README.md`](../tests/fixtures/opencode-headless/README.md).
It does not prove live provider execution or server-side session persistence.
Post-apply smoke test `002` checks that the deployed command and interpreter
start. A new managed path also needs the repository's Docker deployment gate.
