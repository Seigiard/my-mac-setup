import { describe, expect, test } from "bun:test";
import { join } from "node:path";

const sourceRoot = process.env.SOURCE_ROOT ?? join(import.meta.dir, "../home");

const modulePath = join(
  sourceRoot,
  "private_dot_config/herdr-app/mods/my-keep-awake/keep-awake.js",
);

interface Terminal {
  address: string;
  state: string;
  status: string | null;
}

interface KeepAwake {
  tick(): void;
}

type Exec = (program: string, args: string[]) => Promise<void>;

type CreateKeepAwake = (dependencies: {
  exec: Exec;
  now: () => number;
  terminals: () => Terminal[];
}) => KeepAwake;

// SAFETY: this test defines the public seam the implementation must export.
const { createKeepAwake } = (await import(modulePath)) as {
  createKeepAwake: CreateKeepAwake;
};

const CAFFEINATE_LEASE = ["caffeinate", ["-d", "-i", "-t", "25"]] as const;

function terminal(address: string, state: string, status: string | null): Terminal {
  return { address, state, status };
}

async function settle(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

describe("keep-awake lease", () => {
  test("renews a caffeinate lease after 15000 milliseconds while the first lease is in flight", async () => {
    // #given a local working terminal and an exec call that has not completed
    let now = 0;
    let current = [terminal("t7", "live", "working")];
    const calls: Array<[string, string[]]> = [];
    let release!: () => void;

    const inFlight = new Promise<void>((resolve) => {
      release = resolve;
    });

    const keepAwake = createKeepAwake({
      exec: (program, args) => {
        calls.push([program, args]);

        return inFlight;
      },
      now: () => now,
      terminals: () => current,
    });

    // #when timer ticks cross the renewal boundary before the first lease ends
    keepAwake.tick();
    now = 14_999;
    keepAwake.tick();
    now = 15_000;
    keepAwake.tick();

    // #then the recorded boundary has exact initial and renewal lease invocations
    expect(calls).toEqual([CAFFEINATE_LEASE, CAFFEINATE_LEASE]);

    release();
    await settle();
    current = [];
  });

  test("holds through 1199 seconds of quiet and releases after 1201 seconds", async () => {
    // #given a working terminal that becomes quiet after its first lease
    let now = 0;
    let current = [terminal("t7", "live", "working")];
    const calls: Array<[string, string[]]> = [];

    const keepAwake = createKeepAwake({
      exec: async (program, args) => {
        calls.push([program, args]);
      },
      now: () => now,
      terminals: () => current,
    });

    keepAwake.tick();
    await settle();

    // #when the injected clock crosses the deliberate quiet-period boundary
    current = [];
    now = 1_199_000;
    keepAwake.tick();
    await settle();
    now = 1_201_000;
    keepAwake.tick();
    await settle();

    // #then only the initial and in-grace ticks create 25-second leases
    expect(calls).toEqual([CAFFEINATE_LEASE, CAFFEINATE_LEASE]);
  });

  test("restarts the quiet-period clock when local work resumes", async () => {
    // #given a terminal that resumes after the first quiet period begins
    let now = 0;
    let current = [terminal("t7", "live", "working")];
    const calls: Array<[string, string[]]> = [];

    const keepAwake = createKeepAwake({
      exec: async (program, args) => {
        calls.push([program, args]);
      },
      now: () => now,
      terminals: () => current,
    });

    keepAwake.tick();
    await settle();

    // #when work resumes, then the clock advances past its renewed boundary
    current = [];
    now = 1_199_000;
    keepAwake.tick();
    await settle();
    current = [terminal("t7", "live", "working")];
    now = 1_214_000;
    keepAwake.tick();
    await settle();
    current = [];
    now = 2_413_000;
    keepAwake.tick();
    await settle();
    now = 2_415_000;
    keepAwake.tick();
    await settle();

    // #then the renewed grace produces one final lease before it expires
    expect(calls).toEqual([
      CAFFEINATE_LEASE,
      CAFFEINATE_LEASE,
      CAFFEINATE_LEASE,
      CAFFEINATE_LEASE,
    ]);
  });

  test("ignores remote and non-live working terminals but accepts the local control", async () => {
    // #given working terminals that cannot keep this Mac awake and one local control
    const ignoredCalls: Array<[string, string[]]> = [];

    const ignored = createKeepAwake({
      exec: async (program, args) => {
        ignoredCalls.push([program, args]);
      },
      now: () => 0,
      terminals: () => [
        terminal("vps/t7", "live", "working"),
        terminal("t8", "exited", "working"),
      ],
    });

    const localCalls: Array<[string, string[]]> = [];

    const local = createKeepAwake({
      exec: async (program, args) => {
        localCalls.push([program, args]);
      },
      now: () => 0,
      terminals: () => [terminal("t7", "live", "working")],
    });

    // #when each controller receives a timer tick
    ignored.tick();
    local.tick();
    await settle();

    // #then only the local live terminal reaches the lease boundary
    expect([ignoredCalls, localCalls]).toEqual([[], [CAFFEINATE_LEASE]]);
  });

  test("ignores quiet local statuses but accepts a local working control", async () => {
    // #given every local status that is not working and the same list with a working control
    const quiet = [
      terminal("t1", "live", "idle"),
      terminal("t2", "live", "done"),
      terminal("t3", "live", "blocked"),
      terminal("t4", "live", null),
    ];

    const quietCalls: Array<[string, string[]]> = [];

    const quietController = createKeepAwake({
      exec: async (program, args) => {
        quietCalls.push([program, args]);
      },
      now: () => 0,
      terminals: () => quiet,
    });

    const workingCalls: Array<[string, string[]]> = [];

    const workingController = createKeepAwake({
      exec: async (program, args) => {
        workingCalls.push([program, args]);
      },
      now: () => 0,
      terminals: () => [...quiet, terminal("t5", "live", "working")],
    });

    // #when both controllers receive a timer tick
    quietController.tick();
    workingController.tick();
    await settle();

    // #then only the list with a working local terminal starts the exact lease
    expect([quietCalls, workingCalls]).toEqual([[], [CAFFEINATE_LEASE]]);
  });

  test("retries after caffeinate rejects without throwing from a tick", async () => {
    // #given exec rejects the first lease and resolves the second
    let attempts = 0;

    const keepAwake = createKeepAwake({
      exec: async () => {
        attempts += 1;

        if (attempts === 1) throw new Error("caffeinate is unavailable");
      },
      now: () => 0,
      terminals: () => [terminal("t7", "live", "working")],
    });

    // #when the rejection settles before the next timer tick
    keepAwake.tick();
    await settle();
    keepAwake.tick();
    await settle();

    // #then the next tick reaches exec again instead of leaving the lease wedged
    expect(attempts).toBe(2);
  });
});
