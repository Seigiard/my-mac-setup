import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { createReapedPid, createSetupWorktree, removeSetupWorktree, type SetupWorktree } from "./fixtures/agent-hooks/setup-worktree.ts";

const CLAUDE_PATH =
  process.env.AGENT_HOOKS_CLAUDE_PATH ?? join(import.meta.dir, "../home/dot_local/lib/agent-hooks/claude.ts");

const temporaryWorktrees: SetupWorktree[] = [];

afterEach(() => {
  for (const worktree of temporaryWorktrees.splice(0)) removeSetupWorktree(worktree);
});

function worktree(): SetupWorktree {
  const created = createSetupWorktree("agent-hooks-claude-");
  temporaryWorktrees.push(created);

  return created;
}

function callClaude(directory: string, command: string) {
  const result = Bun.spawnSync([process.execPath, CLAUDE_PATH], {
    cwd: directory,
    stdin: Buffer.from(JSON.stringify({
      cwd: directory,
      tool_name: "Bash",
      tool_input: { command },
    })),
    stdout: "pipe",
    stderr: "pipe",
  });

  return { exitCode: result.exitCode, stderr: result.stderr.toString(), stdout: result.stdout.toString() };
}

function denied(reason: string): string {
  return `${JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
  }, null, 2)}\n`;
}

describe("Claude PreToolUse setup-status transport", () => {
  test("a running marker blocks a build command but not the same worktree without a marker", () => {
    // #given a linked Git worktree whose setup marker names this live test process
    const fixture = worktree();
    writeFileSync(fixture.marker, `running ${process.pid} ${Date.now() + 60_000}\n`);

    // #when Claude sends the build call before and after the marker is removed
    const blocked = callClaude(fixture.directory, "make test");
    rmSync(fixture.marker);
    const allowed = callClaude(fixture.directory, "make test");

    // #then the hook keeps its successful exit status and sends the deny only while setup exists
    expect([blocked, allowed]).toEqual([
      {
        exitCode: 0,
        stderr: "",
        stdout: denied("worktree-setup-guard: worktree setup is running for 0 s; wait and retry."),
      },
      { exitCode: 0, stderr: "", stdout: "" },
    ]);
  });

  test("a malformed marker and a non-Git directory fail open without stderr", () => {
    // #given one worktree with unreadable setup state and one ordinary directory
    const fixture = worktree();
    writeFileSync(fixture.marker, "not a setup marker\n");
    const nonGit = mkdirSync(join(tmpdir(), `agent-hooks-claude-non-git-${crypto.randomUUID()}`), { recursive: true });

    try {
      // #when both send a build command through the subprocess transport
      const malformed = callClaude(fixture.directory, "bun test");
      const outsideGit = callClaude(nonGit, "bun test");

      // #then each command proceeds with the normal silent success envelope
      expect([malformed, outsideGit]).toEqual([
        { exitCode: 0, stderr: "", stdout: "" },
        { exitCode: 0, stderr: "", stdout: "" },
      ]);
    } finally {
      rmSync(nonGit, { recursive: true, force: true });
    }
  });

  test("a failed setup denies once without letting a harmless command consume the denial", () => {
    // #given a linked worktree whose setup completed with a nonzero exit
    const fixture = worktree();
    writeFileSync(fixture.marker, "done 7 1700000000000\n");
    const reason = "worktree-setup-guard: setup failed with 7; run `mise exec -- make setup`. If that also fails, report and stop.";

    // #when Claude sends a harmless call, then two build calls
    const harmless = callClaude(fixture.directory, "git status");
    const first = callClaude(fixture.directory, "npm test");
    const second = callClaude(fixture.directory, "npm test");

    // #then the failure is delivered exactly once and only the build call consumes it
    expect([harmless, first, second]).toEqual([
      { exitCode: 0, stderr: "", stdout: "" },
      { exitCode: 0, stderr: "", stdout: denied(reason) },
      { exitCode: 0, stderr: "", stdout: "" },
    ]);
  });

  test("an unwritable deny-once record fails open without stderr", () => {
    // #given a failed setup whose marker directory cannot accept its denial record
    const fixture = worktree();
    writeFileSync(fixture.marker, "done 7 1700000000000\n");
    const markerDirectory = dirname(fixture.marker);
    chmodSync(markerDirectory, 0o500);

    try {
      // #when Claude sends consecutive build calls through the hook transport
      const results = [
        callClaude(fixture.directory, "npm test"),
        callClaude(fixture.directory, "npm test"),
      ];

      // #then the hook silently allows rather than risking a permanent block
      expect(results).toEqual([
        { exitCode: 0, stderr: "", stdout: "" },
        { exitCode: 0, stderr: "", stdout: "" },
      ]);
    } finally {
      chmodSync(markerDirectory, 0o700);
    }
  });

  test("a dead running marker blocks as interrupted", async () => {
    // #given a linked worktree whose marker names a child that has exited
    const fixture = worktree();
    const pid = await createReapedPid();
    writeFileSync(fixture.marker, `running ${pid} ${Date.now()}\n`);
    const reason = "worktree-setup-guard: worktree setup was interrupted; run `mise exec -- make setup`. If that also fails, report and stop.";

    // #when Claude sends a build call from that worktree
    const result = callClaude(fixture.directory, "bun test");

    // #then the hook reports the interrupted setup recovery denial
    expect(result).toEqual({ exitCode: 0, stderr: "", stdout: denied(reason) });
  });

  test("a new failed marker denies again after the earlier marker was acknowledged", () => {
    // #given a worktree with one failure marker and a later distinct failure marker
    const fixture = worktree();
    writeFileSync(fixture.marker, "done 7 1700000000000\n");
    const firstReason = "worktree-setup-guard: setup failed with 7; run `mise exec -- make setup`. If that also fails, report and stop.";
    const secondReason = "worktree-setup-guard: setup failed with 8; run `mise exec -- make setup`. If that also fails, report and stop.";

    // #when one call acknowledges the first line and the marker writer records a new failure
    const first = callClaude(fixture.directory, "npm test");
    const acknowledged = callClaude(fixture.directory, "npm test");
    writeFileSync(fixture.marker, "done 8 1700000000001\n");
    const newFailure = callClaude(fixture.directory, "npm test");

    // #then each distinct failure line reaches Claude once
    expect([first, acknowledged, newFailure]).toEqual([
      { exitCode: 0, stderr: "", stdout: denied(firstReason) },
      { exitCode: 0, stderr: "", stdout: "" },
      { exitCode: 0, stderr: "", stdout: denied(secondReason) },
    ]);
  });
});
