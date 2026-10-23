// Adapter-side reader for the marker written by seigi.worktree-setup.
//
// The dispatch core remains synchronous and free of I/O. Adapters call this
// module for the working directory of the intercepted tool call, then pass the
// resulting state into dispatch.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

import type { Decision, SetupState } from "./types.ts";

const MARKER_NAME = "herdr-worktree-setup";

export type SetupObservation = {
  state: SetupState;
  markerPath?: string;
  markerLine?: string;
};

function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);

    return true;
  } catch (error: unknown) {
    return error instanceof Error && "code" in error && error.code === "EPERM";
  }
}

function markerPathFor(directory: string): string | undefined {
  try {
    const path = execFileSync(
      "git",
      ["rev-parse", "--path-format=absolute", "--git-path", MARKER_NAME],
      { cwd: directory, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();

    return path === "" ? undefined : resolve(path);
  } catch {
    return undefined;
  }
}

function readMarkerLine(path: string): string | undefined {
  try {
    const content = readFileSync(path, "utf8").trim();

    return content === "" || content.includes("\n") ? undefined : content;
  } catch {
    return undefined;
  }
}

function denialPath(markerPath: string): string {
  return `${markerPath}.agent-hooks-denied`;
}

function readDenial(markerPath: string, markerLine: string): boolean | undefined {
  try {
    if (!existsSync(denialPath(markerPath))) return false;

    return readFileSync(denialPath(markerPath), "utf8") === markerLine;
  } catch {
    return undefined;
  }
}

function withDenialState(state: SetupState, markerPath: string, markerLine: string): SetupState | undefined {
  const denied = readDenial(markerPath, markerLine);

  if (denied === undefined) return undefined;

  if (state.status === "done") return { ...state, alreadyDenied: denied };

  if (state.status === "running") return { ...state, alreadyDenied: denied };

  return state;
}

/**
 * Read one setup marker. A missing directory, non-Git directory, rev-parse
 * failure, or missing marker is absent. An unreadable or malformed marker, or
 * an unreadable denial record, is unknown; the core treats both as allow.
 */
export function readSetupObservation(directory: string | undefined): SetupObservation {
  if (directory === undefined || directory === "") return { state: { status: "absent" } };

  const markerPath = markerPathFor(directory);

  if (markerPath === undefined || !existsSync(markerPath)) return { state: { status: "absent" } };

  const markerLine = readMarkerLine(markerPath);

  if (markerLine === undefined) return { state: { status: "unknown" } };

  const running = /^running ([1-9]\d*) ([0-9]+)$/.exec(markerLine);

  if (running !== null) {
    const pid = Number(running[1]);
    const startMs = Number(running[2]);

    if (!Number.isSafeInteger(pid) || !Number.isSafeInteger(startMs)) return { state: { status: "unknown" } };

    const base: SetupState = {
      status: "running",
      alive: processIsAlive(pid),
      elapsedMs: Math.max(0, Date.now() - startMs),
    };

    const state = withDenialState(base, markerPath, markerLine);

    return state === undefined
      ? { state: { status: "unknown" } }
      : { state, markerPath, markerLine };
  }

  const done = /^done (-?\d+) ([0-9]+)$/.exec(markerLine);

  if (done === null) return { state: { status: "unknown" } };

  const exit = Number(done[1]);
  const endMs = Number(done[2]);

  if (!Number.isSafeInteger(exit) || !Number.isSafeInteger(endMs)) return { state: { status: "unknown" } };

  const state = withDenialState({ status: "done", exit, alreadyDenied: false }, markerPath, markerLine);

  return state === undefined
    ? { state: { status: "unknown" } }
    : { state, markerPath, markerLine };
}

/** Record that a failed setup denial reached the client transport. */
export function acknowledgeSetupFailure(observation: SetupObservation): boolean {
  if (observation.markerPath === undefined || observation.markerLine === undefined) return false;

  try {
    writeFileSync(denialPath(observation.markerPath), observation.markerLine);

    return true;
  } catch {
    return false;
  }
}

/**
 * Deliver a setup denial, recording the failed marker only after the client
 * transport is ready to show it. Other policy denials must not consume it.
 */
export function shouldDeliverSetupDecision(observation: SetupObservation, decision: Decision): boolean {
  if (
    decision.verdict !== "block" ||
    !decision.reason.startsWith("worktree-setup-guard:") ||
    !isFailedSetup(observation.state)
  ) return true;

  return acknowledgeSetupFailure(observation);
}

export function isFailedSetup(state: SetupState): boolean {
  return (
    (state.status === "done" && state.exit !== 0 && !state.alreadyDenied) ||
    (state.status === "running" && !state.alive && !state.alreadyDenied)
  );
}
