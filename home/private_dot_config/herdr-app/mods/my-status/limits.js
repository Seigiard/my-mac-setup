const CODEX_MAX_AGE = 900;

const CODEX_RETRY_AGE = 300;

// `exec` cannot provide stdin after launch; keep app-server alive until it
// emits id 2 because it exits on EOF before answering.
// The status bar renders only the aggregate reset-credit count, so omit the
// per-credit reset details from this request.
const CODEX_RPC = `{
  printf '%s\\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"my-status","version":"1"}}}' '{"jsonrpc":"2.0","method":"initialized"}' '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}';
  sleep 4;
} | codex app-server 2>/dev/null`;

function pathFor(home, path) {
  return `${home}/${path}`;
}

async function readText(io, path) {
  try {
    return await io.readTextFile(path);
  } catch {
    return null;
  }
}

function parseJson(text) {
  if (text === null) return null;

  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

async function readJson(io, path) {
  return parseJson(await readText(io, path));
}

function roundPython(value) {
  const lower = Math.floor(value);
  const fraction = value - lower;

  if (fraction < 0.5) return lower;

  if (fraction > 0.5) return lower + 1;

  return lower % 2 === 0 ? lower : lower + 1;
}

function formatPercent(value) {
  const percent = Number(value);

  if (percent >= 100) return "⊘100%";

  // Values below 100 are usage, not exhaustion; rounding must not invent a
  // 100% value that the backend did not report.
  return `${Math.min(roundPython(percent), 99)}%`;
}

function formatReset(timestamp, now) {
  const left = Number(timestamp) - now;

  if (!(left > 0)) return null;

  if (left < 3600) return `↻${Math.floor(left / 60)}m`;

  if (left < 86400) return `↻${Math.floor(left / 3600)}:${String(Math.floor(left % 3600 / 60)).padStart(2, "0")}`;

  return `↻${Math.floor(left / 86400)}d${Math.floor(left % 86400 / 3600)}h`;
}

function formatWindow(label, percent, resetsAt, now) {
  const reset = resetsAt ? formatReset(resetsAt, now) : null;

  if (resetsAt && reset === null) return null;

  return `${label}/${formatPercent(percent)}${reset ? ` ${reset}` : ""}`;
}

function formatClaudeLive(data, now) {
  const parts = [];

  for (const [key, label] of [["five_hour", "5h"], ["seven_day", "7d"]]) {
    const window = data?.[key] ?? {};

    if (window.used_percentage === null || window.used_percentage === undefined) continue;

    const rendered = formatWindow(label, window.used_percentage, window.resets_at, now);

    if (rendered) parts.push(rendered);
  }

  return parts.length ? parts.join(" ") : null;
}

function formatClaudeFallback(data, now) {
  const cached = data?.cachedUsageUtilization ?? {};
  const utilization = cached.utilization ?? {};
  const parts = [];

  for (const [key, label] of [["five_hour", "5h"], ["seven_day", "7d"]]) {
    const window = utilization[key] ?? {};

    if (window.utilization === null || window.utilization === undefined) continue;

    const rendered = formatWindow(label, window.utilization, null, now);

    if (rendered) parts.push(rendered);
  }

  if (!parts.length) return null;

  const fetchedAt = Number(cached.fetchedAtMs);
  const hours = (now - fetchedAt / 1000) / 3600;

  if (cached.fetchedAtMs && hours >= 1) {
    const age = hours < 48 ? `${Math.floor(hours)}h` : `${Math.floor(hours / 24)}d`;
    parts[parts.length - 1] += ` (${age} old)`;
  }

  return parts.join(" ");
}

async function loadClaude(io, now) {
  const live = await readJson(io, pathFor(io.home(), ".cache/claude-rate-limits/latest.json"));
  const liveText = live ? formatClaudeLive(live, now) : null;
  const text = liveText ?? formatClaudeFallback(await readJson(io, pathFor(io.home(), ".claude/.claude.json")), now);

  return text ? { provider: "claude", text } : null;
}

function codexWindowLabel(minutes) {
  return minutes >= 1440 ? `${Math.floor(minutes / 1440)}d` : `${Math.floor(minutes / 60)}h`;
}

function formatCodex(data, now) {
  const parts = [];

  for (const window of Array.isArray(data?.windows) ? data.windows : []) {
    const minutes = Number(window.window_minutes) || 0;
    const rendered = formatWindow(codexWindowLabel(minutes), window.used_percent, window.resets_at, now);

    if (rendered) parts.push(rendered);
  }

  if (!parts.length) return null;

  // A percentage describes usage, not whether requests are allowed; use the
  // backend's blocked flag and avoid a duplicate exhaustion mark at 100%.
  const blocked = data.blocked && !parts.some((part) => part.includes("100%")) ? "⊘" : "";
  const fetchedAt = Number(data.fetched_at) || 0;
  const age = now - fetchedAt;

  if (age >= 3600) {
    const hours = age / 3600;
    const old = hours < 48 ? `${Math.floor(hours)}h` : `${Math.floor(hours / 24)}d`;
    parts[parts.length - 1] += ` (${old} old)`;
  }

  const credits = Number(data.reset_credits) || 0;

  if (credits) parts.push(`×${credits}`);

  return `${blocked}${parts.join(" ")}`;
}

async function commandAvailable(io) {
  try {
    const result = await io.exec("sh", ["-c", "command -v codex >/dev/null 2>&1"]);

    return result.code === 0;
  } catch {
    return false;
  }
}

function rpcReply(stdout) {
  for (const line of stdout.split("\n")) {
    try {
      const message = JSON.parse(line);

      if (message.id === 2 && message.result) return message.result;
    } catch {}
  }

  return null;
}

function cacheFromReply(result, now) {
  // Read limits from the app-server response, not rollout data: OpenCode
  // spends the same account, but its rollout output has no rate-limit data.
  const windows = [];
  const rateLimits = result.rateLimits ?? {};

  for (const slot of ["primary", "secondary"]) {
    const window = rateLimits[slot] ?? {};

    if (window.usedPercent === null || window.usedPercent === undefined) continue;

    windows.push({
      used_percent: window.usedPercent,
      window_minutes: window.windowDurationMins ?? null,
      resets_at: window.resetsAt ?? null,
    });
  }

  return {
    fetched_at: Math.floor(now),
    windows,
    blocked: result.ordinaryUsageAllowed === false,
    reset_credits: result.rateLimitResetCredits?.availableCount || 0,
  };
}

async function writeAttempt(io, path, expected, now) {
  try {
    await io.writeTextFile(path, `${Math.floor(now)}\n`, expected);
  } catch {}
}

async function refreshCodex(io, cachePath, cache, now) {
  const directory = pathFor(io.home(), ".cache/codex-rate-limits");
  const attemptPath = `${directory}/last-attempt`;

  try {
    const mkdir = await io.exec("mkdir", ["-p", directory]);

    if (mkdir.code !== 0) return cache;
  } catch {
    return cache;
  }

  const attemptText = await readText(io, attemptPath);
  const lastAttempt = attemptText !== null && /^\d+$/.test(attemptText.trim()) ? Number(attemptText.trim()) : 0;

  if (lastAttempt && now - lastAttempt < CODEX_RETRY_AGE) return cache;

  let result;

  try {
    result = await io.exec("sh", ["-c", CODEX_RPC]);
  } catch {
    await writeAttempt(io, attemptPath, attemptText, now);

    return cache;
  }

  const reply = result.code === 0 ? rpcReply(result.stdout) : null;

  if (!reply) {
    await writeAttempt(io, attemptPath, attemptText, now);

    return cache;
  }

  const next = cacheFromReply(reply, now);

  try {
    await io.writeTextFile(cachePath, JSON.stringify(next), cache.text);
    await io.exec("rm", ["-f", attemptPath]);

    return { data: next, text: JSON.stringify(next) };
  } catch {
    await writeAttempt(io, attemptPath, attemptText, now);

    return cache;
  }
}

async function loadCodex(io, now) {
  // A cache without the executable cannot be refreshed, so hide a possibly
  // stale Codex segment when the provider is unavailable.
  if (!(await commandAvailable(io))) return null;

  const cachePath = pathFor(io.home(), ".cache/codex-rate-limits/latest.json");
  const cacheText = await readText(io, cachePath);
  const cache = { data: parseJson(cacheText), text: cacheText };
  const fetchedAt = Number(cache.data?.fetched_at);
  const age = now - (Number.isFinite(fetchedAt) ? fetchedAt : 0);
  const current = age >= CODEX_MAX_AGE ? await refreshCodex(io, cachePath, cache, now) : cache;
  const text = formatCodex(current.data, now);

  return text ? { provider: "codex", text } : null;
}

export async function loadLimits(io) {
  const now = io.now();
  const limits = [];
  const claude = await loadClaude(io, now);
  const codex = await loadCodex(io, now);

  if (claude) limits.push(claude);

  if (codex) limits.push(codex);

  return limits;
}
