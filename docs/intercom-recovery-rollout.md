# Intercom recovery: two-machine update

Use this procedure for the root/handle migration in #402 on each of the two
macOS machines. The user deploys it. Record the machine, revision, pending
obligations and observer PID before moving to the other machine.

1. Close participating Claude/cci, OpenCode and Pi clients. Confirm their native
   processes have exited, including any Claude process that outlived cci. Keep
   the old observer running while it finishes recovery.
2. Inspect the old observer's diagnostics and remaining active obligations.
   Resolve pending socket, process-identity or ownership evidence with the old
   engine before the cutover. A quiet log, an absent record or elapsed time does
   not prove settlement. Preserve unsupported records and report their paths and
   reasons; unknown legacy identity never authorizes release or deletion. If a
   pending obligation cannot be resolved, stop the cutover and decide its handling
   explicitly rather than resetting the recovery directory.
3. Stop the old job with `launchctl bootout gui/$(id -u)/com.seigiard.herdr-agent-intercom-recovery`.
   Confirm the job and its recorded PID/start identity are gone. Retain the
   recovery store, archives and sequence high-water marks.
4. Sync the tested revision into chezmoi's source clone, then deploy engine,
   launcher, Claude bridge, native leaf, release hook and launchd plist together.
   The working checkout is not chezmoi's default source. Keep the same
   `XDG_STATE_HOME` when rendering the job and starting clients. No participating
   client may run during this step; old flags and path-based handles are removed.
5. Restart the installed observer before opening a client. Run
   `launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.seigiard.herdr-agent-intercom-recovery.plist"`.
   Check `launchctl print gui/$(id -u)/com.seigiard.herdr-agent-intercom-recovery`
   and the readiness receipt in the configured recovery root. Its live PID/start
   identity, `state_root`, label and engine digest must describe this deployment.
   A stale receipt is not readiness. Preserve and report any unsupported-record
   diagnostics rather than converting them into successful cleanup.
6. Start new clients from the managed shell environment. Check a fresh-pane
   enrollment, Claude's first-prompt handoff and cleanup after native exit.
   Confirm the Herdr alias agrees with Intercom's own identity. Record outcomes
   for this machine, then repeat the stopped-client procedure on the second.

Rollback also requires stopped clients and resolved obligations. Restore engine,
callers and job from one revision together; retain the state store and verify the
restored observer before starting clients. Do not run mixed versions to test a
rollback.

The recovery root is separate from broker runtime. Caller interfaces take only
that root and opaque intent IDs; storage paths are diagnostic details owned by
the engine. CLI usage is available from
`python3 ~/.local/lib/intercom-claim-recovery.py --help`.
