import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { z } from "zod";


const SUBJECT_PATH = process.env.MY_STATUS_LIMITS_PATH ?? join(import.meta.dir, "../home/private_dot_config/herdr-app/mods/my-status/limits.js");

const NOW = 1_700_000_000;

const temporaryPaths: string[] = [];


type JsonValue = boolean | number | string | null | JsonObject | JsonValue[];

type JsonObject = { [key: string]: JsonValue };

type Limit = { provider: "claude" | "codex"; text: string };

type ExecResult = { code: number; stdout: string; stderr: string };

type LimitsIo = {
  home: () => string;
  now: () => number;
  exec: (program: string, args: string[]) => Promise<ExecResult>;
  readTextFile: (path: string) => Promise<string | null>;
  writeTextFile: (path: string, text: string, expected: string | null) => Promise<null>;
};

const RpcRequestSchema = z.object({
  jsonrpc: z.literal("2.0"),
  id: z.number().optional(),
  method: z.string(),
  params: z.object({
    clientInfo: z.object({ name: z.string(), version: z.string() }).optional(),
    excludeResetCreditDetails: z.boolean().optional(),
  }).optional(),
});

const ClientInfoSchema = z.object({ name: z.string(), version: z.string() });

const CodexReplySchema = z.object({
  id: z.literal(2),
  result: z.object({
    rateLimits: z.object({
      primary: z.object({ usedPercent: z.number(), windowDurationMins: z.number(), resetsAt: z.number() }),
    }),
    ordinaryUsageAllowed: z.boolean(),
    rateLimitResetCredits: z.object({ availableCount: z.number() }),
  }),
});

const CodexErrorSchema = z.object({
  id: z.literal(2),
  error: z.object({ message: z.string().optional() }).passthrough(),
});

const CodexCacheSchema = z.object({
  fetched_at: z.number(),
  windows: z.array(z.object({ used_percent: z.number(), window_minutes: z.number(), resets_at: z.number() })),
  blocked: z.boolean(),
  reset_credits: z.number(),
});

function temporaryDir(prefix: string): string {
  const path = mkdtempSync(join(tmpdir(), prefix));
  temporaryPaths.push(path);

  return path;
}

function writeJson(path: string, value: JsonObject): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(value));
}

function claudeCache(home: string, windows: JsonObject): void {
  writeJson(join(home, ".cache/claude-rate-limits/latest.json"), { fetched_at: NOW, ...windows });
}

function codexCache(home: string, value: JsonObject): void {
  writeJson(join(home, ".cache/codex-rate-limits/latest.json"), { fetched_at: NOW, ...value });
}

function codexReply(usedPercent = 7) {
  return {
    id: 2,
    result: {
      rateLimits: {
        primary: { usedPercent, windowDurationMins: 10080, resetsAt: NOW + 86_399 },
      },
      ordinaryUsageAllowed: true,
      rateLimitResetCredits: { availableCount: 1 },
    },
  } satisfies JsonObject;
}

function fakeCodex(bin: string, marker: string, reply: JsonObject | null): void {
  const response = reply ? JSON.stringify(reply).replace(/'/g, "'\\''") : "";
  const executable = join(bin, "codex");
  writeFileSync(executable, `#!/bin/bash
while IFS= read -r request; do
  printf '%s\\n' "$request" >> "$MMS_CODEX_MARKER"
  case "$request" in
    *'"id":2'*)
      cat <&0 >/dev/null &
      eof_probe=$!
      sleep 1
      if kill -0 "$eof_probe" 2>/dev/null; then
        kill "$eof_probe"
        wait "$eof_probe" 2>/dev/null
        ${reply ? `printf '%s\\n' '${response}'` : ":"}
      fi
      exit 0
      ;;
  esac
done
`);
  chmodSync(executable, 0o755);
}

function ioFor(home: string, options: {
  now?: number;
  path?: string;
  processHome?: string;
  calls?: string[];
  rejectReads?: ReadonlySet<string>;
  rejectWrites?: ReadonlySet<string>;
  rejectExec?: boolean;
} = {}): LimitsIo {
  return {
    home: () => home,
    now: () => options.now ?? NOW,
    exec: async (program, args) => {
      options.calls?.push(`${program} ${args.join(" ")}`);

      if (options.rejectExec) throw new Error(`cannot start ${program}`);

      const child = Bun.spawn([program, ...args], {
        env: {
          HOME: options.processHome ?? home,
          PATH: options.path ?? "/usr/bin:/bin",
          MMS_CODEX_MARKER: join(home, "codex.requests"),
        },
        stdout: "pipe",
        stderr: "pipe",
      });

      const [code, stdout, stderr] = await Promise.all([
        child.exited,
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
      ]);

      return { code, stdout, stderr };
    },
    readTextFile: async (path) => {
      if (options.rejectReads?.has(path)) throw new Error(`cannot read ${path}`);

      try {
        return readFileSync(path, "utf8");
      } catch {
        return null;
      }
    },
    writeTextFile: async (path, text, expected) => {
      if (options.rejectWrites?.has(path)) throw new Error(`cannot write ${path}`);

      const current = existsSync(path) ? readFileSync(path, "utf8") : null;

      if (current !== expected) throw new Error(`stale snapshot for ${path}`);
      writeFileSync(path, text);

      return null;
    },
  };
}

async function loadLimits(io: LimitsIo): Promise<Limit[]> {
  const subject = await import(SUBJECT_PATH);

  return subject.loadLimits(io);
}

function parseReply(lines: string): z.infer<typeof CodexReplySchema> | null {
  for (const line of lines.split("\n")) {
    try {
      const result = CodexReplySchema.safeParse(JSON.parse(line));

      if (result.success) return result.data;
    } catch {}
  }

  return null;
}

afterEach(() => {
  for (const path of temporaryPaths.splice(0)) rmSync(path, { recursive: true, force: true });
});

describe("my-status account limits", () => {
  test("renders live Claude windows with compact reset countdowns", async () => {
    // #given
    const home = temporaryDir("my-status-claude-live-");
    claudeCache(home, {
      five_hour: { used_percentage: 3, resets_at: NOW + 3_599 },
      seven_day: { used_percentage: 18, resets_at: NOW + 356_450 },
    });

    // #when
    const limits = await loadLimits(ioFor(home));

    // #then
    expect(limits).toEqual([{ provider: "claude", text: "5h/3% ↻59m 7d/18% ↻4d3h" }]);
  });

  test("drops a Claude window whose reset has passed", async () => {
    // #given
    const home = temporaryDir("my-status-claude-expired-");
    claudeCache(home, {
      five_hour: { used_percentage: 3, resets_at: NOW - 1 },
      seven_day: { used_percentage: 18, resets_at: NOW + 90_050 },
    });

    // #when
    const limits = await loadLimits(ioFor(home));

    // #then
    expect(limits).toEqual([{ provider: "claude", text: "7d/18% ↻1d1h" }]);
  });

  test("uses the Claude fallback only when the live cache is absent and labels its age", async () => {
    // #given
    const home = temporaryDir("my-status-claude-fallback-");
    writeJson(join(home, ".claude/.claude.json"), {
      cachedUsageUtilization: {
        fetchedAtMs: (NOW - 7 * 86_400) * 1_000,
        utilization: { five_hour: { utilization: 88 } },
      },
    });

    // #when
    const fallback = await loadLimits(ioFor(home));
    claudeCache(home, { five_hour: { used_percentage: 3, resets_at: NOW + 3_599 } });
    const live = await loadLimits(ioFor(home));

    // #then
    expect([fallback, live]).toEqual([
      [{ provider: "claude", text: "5h/88% (7d old)" }],
      [{ provider: "claude", text: "5h/3% ↻59m" }],
    ]);
  });

  test("marks only a real 100 percent Claude window as exhausted", async () => {
    // #given
    const home = temporaryDir("my-status-claude-exhausted-");
    claudeCache(home, { five_hour: { used_percentage: 100, resets_at: NOW + 3_599 } });

    // #when
    const exhausted = await loadLimits(ioFor(home));
    claudeCache(home, { five_hour: { used_percentage: 99.6, resets_at: NOW + 3_599 } });
    const nearlyExhausted = await loadLimits(ioFor(home));

    // #then
    expect([exhausted, nearlyExhausted]).toEqual([
      [{ provider: "claude", text: "5h/⊘100% ↻59m" }],
      [{ provider: "claude", text: "5h/99% ↻59m" }],
    ]);
  });

  test("formats cached Codex limits, blocked state, credits, and age", async () => {
    // #given
    const home = temporaryDir("my-status-codex-cache-");
    const bin = join(home, "bin");
    mkdirSync(bin, { recursive: true });
    fakeCodex(bin, join(home, "codex.requests"), null);
    codexCache(home, {
      fetched_at: NOW - 3_600,
      windows: [{ used_percent: 40, window_minutes: 300, resets_at: NOW + 3_599 }],
      blocked: true,
      reset_credits: 2,
    });

    // #when
    const limits = await loadLimits(ioFor(home, { path: `${bin}:${process.env.PATH}` }));

    // #then
    expect(limits).toEqual([{ provider: "codex", text: "⊘5h/40% ↻59m (1h old) ×2" }]);
  }, 20_000);

  test("renders a fresh Codex cache without starting app-server", async () => {
    // #given
    const home = temporaryDir("my-status-codex-fresh-");
    const bin = join(home, "bin");
    mkdirSync(bin, { recursive: true });
    fakeCodex(bin, join(home, "codex.requests"), codexReply());
    codexCache(home, {
      fetched_at: NOW - 899,
      windows: [{ used_percent: 40, window_minutes: 10080, resets_at: NOW + 86_399 }],
      blocked: false,
      reset_credits: 0,
    });

    // #when
    const limits = await loadLimits(ioFor(home, { path: `${bin}:${process.env.PATH}` }));

    // #then
    expect({ limits, appServerStarted: existsSync(join(home, "codex.requests")) }).toEqual({
      limits: [{ provider: "codex", text: "7d/40% ↻23:59" }],
      appServerStarted: false,
    });
  });

  test("refreshes stale Codex data through the JSON-RPC handshake and renders it immediately", async () => {
    // #given
    const home = temporaryDir("my-status-codex-refresh-");
    const bin = join(home, "bin");
    mkdirSync(bin, { recursive: true });
    fakeCodex(bin, join(home, "codex.requests"), codexReply());
    codexCache(home, {
      fetched_at: NOW - 901,
      windows: [{ used_percent: 40, window_minutes: 10080, resets_at: NOW + 86_399 }],
      blocked: false,
      reset_credits: 0,
    });

    // #when
    const limits = await loadLimits(ioFor(home, { path: `${bin}:${process.env.PATH}` }));
    const requests = readFileSync(join(home, "codex.requests"), "utf8").trim().split("\n").map((line) => RpcRequestSchema.parse(JSON.parse(line)));
    const cache = CodexCacheSchema.parse(JSON.parse(readFileSync(join(home, ".cache/codex-rate-limits/latest.json"), "utf8")));
    const [initialize, initialized, read] = requests;

    // #then
    expect({
      limits,
      handshake: {
        initialize: {
          jsonrpc: initialize?.jsonrpc,
          id: initialize?.id,
          method: initialize?.method,
          clientInfoHasRequiredStrings: ClientInfoSchema.safeParse(initialize?.params?.clientInfo).success,
        },
        initialized: { jsonrpc: initialized?.jsonrpc, method: initialized?.method },
        read: { jsonrpc: read?.jsonrpc, id: read?.id, method: read?.method, params: read?.params },
      },
      cache,
    }).toEqual({
      limits: [{ provider: "codex", text: "7d/7% ↻23:59 ×1" }],
      handshake: {
        initialize: { jsonrpc: "2.0", id: 1, method: "initialize", clientInfoHasRequiredStrings: true },
        initialized: { jsonrpc: "2.0", method: "initialized" },
        read: { jsonrpc: "2.0", id: 2, method: "account/rateLimits/read", params: { excludeResetCreditDetails: true } },
      },
      cache: {
        fetched_at: NOW,
        windows: [{ used_percent: 7, window_minutes: 10080, resets_at: NOW + 86_399 }],
        blocked: false,
        reset_credits: 1,
      },
    });
  }, 20_000);

  test("backs off failed Codex refreshes and removes the marker after a retry succeeds", async () => {
    // #given
    const home = temporaryDir("my-status-codex-backoff-");
    const bin = join(home, "bin");
    mkdirSync(bin, { recursive: true });
    fakeCodex(bin, join(home, "codex.requests"), null);
    codexCache(home, {
      fetched_at: NOW - 901,
      windows: [{ used_percent: 40, window_minutes: 10080, resets_at: NOW + 86_399 }],
      blocked: false,
      reset_credits: 0,
    });
    const path = `${bin}:${process.env.PATH}`;

    // #when
    const first = await loadLimits(ioFor(home, { path }));
    const suppressed = await loadLimits(ioFor(home, { path }));
    fakeCodex(bin, join(home, "codex.requests"), codexReply());
    const retried = await loadLimits(ioFor(home, { now: NOW + 301, path }));

    // #then
    expect({ first, suppressed, retried, requests: readFileSync(join(home, "codex.requests"), "utf8").trim().split("\n").length, marker: existsSync(join(home, ".cache/codex-rate-limits/last-attempt")) }).toEqual({
      first: [{ provider: "codex", text: "7d/40% ↻23:59" }],
      suppressed: [{ provider: "codex", text: "7d/40% ↻23:59" }],
      retried: [{ provider: "codex", text: "7d/7% ↻23:54 ×1" }],
      requests: 6,
      marker: false,
    });
  }, 20_000);

  test("ports 27212: renders Claude before Codex with both providers' complete figures", async () => {
    // #given
    const home = temporaryDir("my-status-provider-order-");
    const bin = join(home, "bin");
    mkdirSync(bin, { recursive: true });
    fakeCodex(bin, join(home, "codex.requests"), null);
    claudeCache(home, {
      five_hour: { used_percentage: 1, resets_at: NOW + 6_530 },
      seven_day: { used_percentage: 18, resets_at: NOW + 356_450 },
    });
    codexCache(home, {
      windows: [{ used_percent: 2, window_minutes: 10080, resets_at: NOW + 558_050 }],
      blocked: false,
      reset_credits: 1,
    });

    // #when
    const limits = await loadLimits(ioFor(home, { path: `${bin}:${process.env.PATH}` }));

    // #then
    expect(limits).toEqual([
      { provider: "claude", text: "5h/1% ↻1:48 7d/18% ↻4d3h" },
      { provider: "codex", text: "7d/2% ↻6d11h ×1" },
    ]);
  });

  test("ports 27204: returns no segments when every provider window has expired", async () => {
    // #given
    const home = temporaryDir("my-status-all-expired-");
    const bin = join(home, "bin");
    mkdirSync(bin, { recursive: true });
    fakeCodex(bin, join(home, "codex.requests"), null);
    claudeCache(home, { five_hour: { used_percentage: 3, resets_at: NOW - 1 } });
    codexCache(home, {
      windows: [{ used_percent: 15, window_minutes: 10080, resets_at: NOW - 1 }],
      blocked: false,
      reset_credits: 0,
    });

    // #when
    const limits = await loadLimits(ioFor(home, { path: `${bin}:${process.env.PATH}` }));

    // #then
    expect(limits).toEqual([]);
  });

  test("ports 27207: formats blocked Codex accounts without duplicating exhaustion", async () => {
    // #given
    const home = temporaryDir("my-status-codex-blocked-");
    const bin = join(home, "bin");
    mkdirSync(bin, { recursive: true });
    fakeCodex(bin, join(home, "codex.requests"), null);
    const io = ioFor(home, { path: `${bin}:${process.env.PATH}` });

    const render = async (usedPercent: number, blocked: boolean, credits: number) => {
      codexCache(home, {
        windows: [{ used_percent: usedPercent, window_minutes: 10080, resets_at: NOW + 86_399 }],
        blocked,
        reset_credits: credits,
      });

      return loadLimits(io);
    };

    // #when
    const rendered = [
      await render(100, true, 2),
      await render(100, true, 0),
      await render(40, true, 0),
      await render(40, false, 0),
    ];

    // #then
    expect(rendered).toEqual([
      [{ provider: "codex", text: "7d/⊘100% ↻23:59 ×2" }],
      [{ provider: "codex", text: "7d/⊘100% ↻23:59" }],
      [{ provider: "codex", text: "⊘7d/40% ↻23:59" }],
      [{ provider: "codex", text: "7d/40% ↻23:59" }],
    ]);
  });

  test("ports 27208: labels only Codex snapshots at least one hour old", async () => {
    // #given
    const home = temporaryDir("my-status-codex-age-");
    const bin = join(home, "bin");
    mkdirSync(bin, { recursive: true });
    fakeCodex(bin, join(home, "codex.requests"), null);
    const io = ioFor(home, { path: `${bin}:${process.env.PATH}` });

    const render = async (age: number) => {
      codexCache(home, {
        fetched_at: NOW - age,
        windows: [{ used_percent: 40, window_minutes: 10080, resets_at: NOW + 86_399 }],
        blocked: false,
        reset_credits: 0,
      });

      return loadLimits(io);
    };

    // #when
    const rendered = [await render(1_140), await render(3_600), await render(48 * 3_600)];

    // #then
    expect(rendered).toEqual([
      [{ provider: "codex", text: "7d/40% ↻23:59" }],
      [{ provider: "codex", text: "7d/40% ↻23:59 (1h old)" }],
      [{ provider: "codex", text: "7d/40% ↻23:59 (2d old)" }],
    ]);
  }, 20_000);

  test("ports 27211 and 27205: formats compact resets and a three-hour Claude fallback age", async () => {
    // #given
    const home = temporaryDir("my-status-claude-compact-");
    claudeCache(home, {
      five_hour: { used_percentage: 3, resets_at: NOW + 7_250 },
      seven_day: { used_percentage: 15, resets_at: NOW + 90_050 },
    });

    // #when
    const live = await loadLimits(ioFor(home));
    rmSync(join(home, ".cache/claude-rate-limits/latest.json"));
    writeJson(join(home, ".claude/.claude.json"), {
      cachedUsageUtilization: {
        fetchedAtMs: (NOW - 3 * 3_600) * 1_000,
        utilization: { five_hour: { utilization: 88 } },
      },
    });
    const fallback = await loadLimits(ioFor(home));

    // #then
    expect([live, fallback]).toEqual([
      [{ provider: "claude", text: "5h/3% ↻2:00 7d/15% ↻1d1h" }],
      [{ provider: "claude", text: "5h/88% (3h old)" }],
    ]);
  });

  test("refreshes a missing Codex cache by creating its folder and renders the new figure", async () => {
    // #given
    const home = temporaryDir("my-status-codex-missing-cache-");
    const bin = join(home, "bin");
    mkdirSync(bin, { recursive: true });
    fakeCodex(bin, join(home, "codex.requests"), codexReply());

    // #when
    const limits = await loadLimits(ioFor(home, { path: `${bin}:${process.env.PATH}` }));

    // #then
    expect({ limits, cacheWritten: existsSync(join(home, ".cache/codex-rate-limits/latest.json")) }).toEqual({
      limits: [{ provider: "codex", text: "7d/7% ↻23:59 ×1" }],
      cacheWritten: true,
    });
  }, 20_000);

  test("treats malformed or unreadable Claude data as absent while preserving fresh Codex data", async () => {
    // #given
    const home = temporaryDir("my-status-claude-unavailable-");
    const bin = join(home, "bin");
    const claudePath = join(home, ".cache/claude-rate-limits/latest.json");
    mkdirSync(dirname(claudePath), { recursive: true });
    mkdirSync(bin, { recursive: true });
    writeFileSync(claudePath, "{");
    fakeCodex(bin, join(home, "codex.requests"), null);
    codexCache(home, {
      fetched_at: NOW,
      windows: [{ used_percent: 40, window_minutes: 10080, resets_at: NOW + 86_399 }],
      blocked: false,
      reset_credits: 0,
    });

    // #when
    const malformed = await loadLimits(ioFor(home, { path: `${bin}:${process.env.PATH}` }));
    writeJson(claudePath, { five_hour: { used_percentage: 3, resets_at: NOW + 3_599 } });

    const rejected = await loadLimits(ioFor(home, {
      path: `${bin}:${process.env.PATH}`,
      rejectReads: new Set([claudePath]),
    }));

    // #then
    expect([malformed, rejected]).toEqual([
      [{ provider: "codex", text: "7d/40% ↻23:59" }],
      [{ provider: "codex", text: "7d/40% ↻23:59" }],
    ]);
  });

  test("treats a malformed Codex cache as missing and refreshes it", async () => {
    // #given
    const home = temporaryDir("my-status-codex-malformed-");
    const bin = join(home, "bin");
    const cachePath = join(home, ".cache/codex-rate-limits/latest.json");
    mkdirSync(dirname(cachePath), { recursive: true });
    mkdirSync(bin, { recursive: true });
    writeFileSync(cachePath, "{");
    fakeCodex(bin, join(home, "codex.requests"), codexReply());

    // #when
    const limits = await loadLimits(ioFor(home, { path: `${bin}:${process.env.PATH}` }));

    // #then
    expect(limits).toEqual([{ provider: "codex", text: "7d/7% ↻23:59 ×1" }]);
  }, 20_000);

  test("records a failed refresh when writing its latest Codex cache is rejected", async () => {
    // #given
    const home = temporaryDir("my-status-codex-write-rejected-");
    const bin = join(home, "bin");
    const cachePath = join(home, ".cache/codex-rate-limits/latest.json");
    mkdirSync(bin, { recursive: true });
    fakeCodex(bin, join(home, "codex.requests"), codexReply());
    codexCache(home, {
      fetched_at: NOW - 901,
      windows: [{ used_percent: 40, window_minutes: 10080, resets_at: NOW + 86_399 }],
      blocked: false,
      reset_credits: 0,
    });

    // #when
    const limits = await loadLimits(ioFor(home, {
      path: `${bin}:${process.env.PATH}`,
      rejectWrites: new Set([cachePath]),
    }));

    // #then
    expect({ limits, backedOff: existsSync(join(home, ".cache/codex-rate-limits/last-attempt")) }).toEqual({
      limits: [{ provider: "codex", text: "7d/40% ↻23:59" }],
      backedOff: true,
    });
  }, 20_000);

  test("returns Claude alone when every exec call rejects", async () => {
    // #given
    const home = temporaryDir("my-status-exec-rejected-");
    claudeCache(home, { five_hour: { used_percentage: 3, resets_at: NOW + 3_599 } });
    codexCache(home, {
      fetched_at: NOW,
      windows: [{ used_percent: 40, window_minutes: 10080, resets_at: NOW + 86_399 }],
      blocked: false,
      reset_credits: 0,
    });

    // #when
    const limits = await loadLimits(ioFor(home, { rejectExec: true }));

    // #then
    expect(limits).toEqual([{ provider: "claude", text: "5h/3% ↻59m" }]);
  });

  test("returns no Codex segment when app-server cannot run, even with a cache", async () => {
    // #given
    const home = temporaryDir("my-status-no-sources-");
    codexCache(home, {
      windows: [{ used_percent: 40, window_minutes: 10080, resets_at: NOW + 86_399 }],
      blocked: false,
      reset_credits: 0,
    });

    // #when
    const limits = await loadLimits(ioFor(home, { path: "/bin:/usr/bin" }));

    // #then
    expect(limits).toEqual([]);
  }, 20_000);
});

const liveCodex = process.env.MMS_LIVE_CODEX_TEST === "1";

const liveCodexAvailable = liveCodex && Bun.which("codex") !== null;

const unavailableCodexErrorMessages = [
  "authentication required to read rate limits",
  "failed to fetch codex rate limits",
];

test.skipIf(!liveCodexAvailable)("live Codex reply keeps the fake's five consumed fields and a real refresh works in a temp home (set MMS_LIVE_CODEX_TEST=1)", async () => {
  // #given
  const home = temporaryDir("my-status-live-codex-");
  const direct = Bun.spawn(["codex", "app-server"], { stdin: "pipe", stdout: "pipe", stderr: "ignore", env: process.env });
  const request = (value: JsonObject) => direct.stdin.write(`${JSON.stringify(value)}\n`);
  request({ jsonrpc: "2.0", id: 1, method: "initialize", params: { clientInfo: { name: "my-status-test", version: "1" } } });
  request({ jsonrpc: "2.0", method: "initialized" });
  request({ jsonrpc: "2.0", id: 2, method: "account/rateLimits/read", params: { excludeResetCreditDetails: true } });
  const reader = direct.stdout.getReader();
  const decoder = new TextDecoder();
  let real = "";
  let reply: z.infer<typeof CodexReplySchema> | null = null;
  let unmatchedIdTwoLine: string | null = null;
  let unavailableIdTwoErrorLine: string | null = null;
  let rejectedIdTwoErrorLine: string | null = null;
  let timedOut = false;

  try {
    while (!reply) {
      const chunk = await Promise.race([
        reader.read(),
        Bun.sleep(10_000).then(() => ({ done: true, timedOut: true })),
      ]);

      if ("timedOut" in chunk) {
        timedOut = true;
        break;
      }

      if (chunk.done) break;
      real += decoder.decode(chunk.value, { stream: true });
      reply = parseReply(real);
      unmatchedIdTwoLine = real.split("\n").find((line) => {
        try {
          const value: unknown = JSON.parse(line);

          return z.object({ id: z.literal(2) }).safeParse(value).success
            && !CodexReplySchema.safeParse(value).success;
        } catch {
          return false;
        }
      }) ?? null;

      const idTwoErrorLines = real.split("\n").flatMap((line) => {
        try {
          const value: unknown = JSON.parse(line);
          const error = CodexErrorSchema.safeParse(value);

          return error.success ? [{ line, message: error.data.error.message }] : [];
        } catch {
          return [];
        }
      });

      unavailableIdTwoErrorLine = idTwoErrorLines.find(({ message }) => message !== undefined && unavailableCodexErrorMessages.some((expected) => message.includes(expected)))?.line ?? null;
      rejectedIdTwoErrorLine = idTwoErrorLines.find(({ line }) => line !== unavailableIdTwoErrorLine)?.line ?? null;
    }
  } finally {
    direct.kill();
    reader.releaseLock();
  }

  if (!reply) {
    throw new Error(unavailableIdTwoErrorLine
      ? `live Codex oracle unavailable: codex app-server returned id 2 with an error: ${unavailableIdTwoErrorLine}`
      : rejectedIdTwoErrorLine
        ? `codex app-server rejected account/rateLimits/read: ${rejectedIdTwoErrorLine}`
      : unmatchedIdTwoLine
        ? `codex app-server returned id 2 but it did not match CodexReplySchema: ${unmatchedIdTwoLine}`
      : timedOut
        ? "live Codex oracle unavailable: codex app-server did not answer account/rateLimits/read within 10 seconds"
        : "codex app-server ended before answering account/rateLimits/read");
  }

  // #when
  const limits = await loadLimits(ioFor(home, {
    path: process.env.PATH ?? "",
    processHome: process.env.HOME,
  }));

  const cache = CodexCacheSchema.parse(JSON.parse(readFileSync(join(home, ".cache/codex-rate-limits/latest.json"), "utf8")));

  // #then
  expect({
    fakeMatchesConsumedReplySchema: CodexReplySchema.safeParse(codexReply()).success,
    realMatchesConsumedReplySchema: CodexReplySchema.safeParse(reply).success,
    rendered: limits.length > 0,
    cached: cache.windows.length > 0,
  }).toEqual({
    fakeMatchesConsumedReplySchema: true,
    realMatchesConsumedReplySchema: true,
    rendered: true,
    cached: true,
  });
}, 20_000);
