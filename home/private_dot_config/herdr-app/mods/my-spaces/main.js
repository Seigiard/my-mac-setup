// Workspace spaces: stable colored avatars, worktrees under their checkout,
// grouped by machine when more than one is known. Each expanded space shows its
// branch, Git counts, pull-request state and its most urgent agent state; the
// agents themselves live in the agents list. Click to switch, right-click for
// its menu, drag to reorder.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { spaces, machines, panes, run, openOverlay, exec, hc, theme, shared, setShared, watchFolder, window, layout } from "herdr";

function find(node, id) {
  if (node?.id === id) return node;

  for (const child of node?.children ?? []) {
    const found = find(child, id);

    if (found) return found;
  }

  return null;
}

// The sidebar's rail goes by its width, not a flag: dragging its edge narrows it too.
const narrow = () => (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;

// Where a space is now: its first terminal's live folder, else where it was made.
// `ps`: panes(), read once by the caller (each read copies every pane).
function place(s, ps) {
  const tabs = new Set((s.tabs ?? []).map((c) => c.id));

  return ps.find((p) => tabs.has(p.tab) && p.cwd)?.cwd || s.folder;
}

const rowHeight = ({ tree, extra }) => (tree ? 28 : 30) + extra * 16;

const where = (s, ps) => JSON.stringify([s.machine ?? null, place(s, ps)]);

const base = (path) => path.replace(/\/+$/, "").split("/").pop();

// Changes made outside Herdr (an editor's save, a commit in another app): looked
// for this often, in repos the list shows, while the window is in front.
const FALLBACK = 60000;

const PR_FALLBACK = 120000;

const CHECK_RUN_FAIL = new Set(["FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"]);

const CHECK_RUN_NEUTRAL = new Set(["SKIPPED", "CANCELLED", "NEUTRAL", "STALE"]);

const STATUS_FAIL = new Set(["FAILURE", "ERROR"]);

// What a stored color name looks like on an avatar (the same in every mod
// that draws space avatars): one strong color per hue, light and dark alike.
const MARK = { ansi6: "#22a99a", ansi3: "#e3814f", ansi4: "#5b8def", ansi5: "#8b7cf6", ansi2: "#3fae6a", ansi1: "#d9649a" };

function normalizeCheck(check) {
  if (check?.__typename === "CheckRun") {
    if (check.status !== "COMPLETED") return "pending";

    if (check.conclusion === "SUCCESS") return "pass";

    if (CHECK_RUN_FAIL.has(check.conclusion)) return "fail";

    if (CHECK_RUN_NEUTRAL.has(check.conclusion)) return "neutral";

    return "neutral";
  }

  if (check?.__typename === "StatusContext") {
    if (check.state === "SUCCESS") return "pass";

    if (STATUS_FAIL.has(check.state)) return "fail";

    return "pending";
  }

  return "neutral";
}

function summarizeChecks(rollup) {
  const counts = { pass: 0, fail: 0, pending: 0, neutral: 0 };

  for (const check of Array.isArray(rollup) ? rollup : []) counts[normalizeCheck(check)] += 1;
  const relevant = counts.pass + counts.fail + counts.pending;
  let state = "none";

  if (counts.fail > 0) state = "fail";
  else if (counts.pending > 0) state = "pending";
  else if (counts.pass > 0) state = "pass";

  return { pass: counts.pass, fail: counts.fail, pending: counts.pending, relevant, state };
}

function prGlyph(state) {
  return { merged: "◆", closed: "⊘", draft: "◌", checks_failed: "⊗", checks_pending: "◐", open: "●" }[state] ?? "●";
}

function prLabel(state) {
  return { merged: "MERGED", closed: "CLOSED", draft: "DRAFT" }[state] ?? null;
}

function checksLabel(checks) {
  if (!checks || checks.state === "none" || checks.relevant === 0) return null;
  const mark = { fail: "✗", pending: "…", pass: "✓" }[checks.state];
  const numerator = checks.state === "fail" ? checks.fail : checks.pass;

  return `${mark} ${numerator}/${checks.relevant}`;
}

function reviewLabel(review) {
  return { APPROVED: "approved", CHANGES_REQUESTED: "changes req", REVIEW_REQUIRED: "review req" }[review] ?? null;
}

// A space speaks up only when something in it needs you.
export function glyph(status) {
  return status === "blocked" || status === "done" ? "●" : "·";
}

export function tone(t, status) {
  return t[status] ?? t.unknown;
}

export default class Spaces extends View {
  init(_props, cx) {
    this.git = {}; // where() -> Git metadata, null: not a repo
    this.checked = {}; // where() -> when it was last looked at
    this.unsure = new Set(); // where()s git couldn't answer for (a machine away)
    this.pending = new Set(); // where()s to look at next
    this.pr = {}; // where() -> PR metadata, null: no PR or unavailable
    this.prChecked = {}; // where() -> when the last PR lookup was queued
    this.prPending = new Set(); // where()s to look at next
    this.busy = {}; // pane -> an agent working or a program in front of its shell
    this.ready = {}; // machine -> its layout was readable at the last look
    this.at = {}; // space -> its where() at the last look
    this.watching = new Set(); // local repos' git folders
    // Spaces made while this runs wait (at most a moment) for their git, so a
    // worktree appears under its repo instead of jumping there.
    this.shown = new Set(spaces().map((s) => s.id));
    this.born = {};
    this.pressed = null;
    this.over = null;
    this.machines = [];
    this.reconnecting = JSON.parse(localStorage.getItem("machines.reconnecting") ?? "{}");

    for (const state of Object.values(this.reconnecting)) state.busy = false;
    this.folded = new Set(JSON.parse(localStorage.getItem("machines.folded") ?? "[]"));
    this.refreshMachines(cx);
    cx.timer.every(15000, cx => this.refreshMachines(cx));
    // `git status` walks the whole tree, on another machine a process there:
    // only when its answer could have changed (see `due`).
    cx.timer.every(250, (cx) => this.checkNew(cx));
  }

  checkNew(cx) {
    const now = Date.now();
    const sp = spaces();

    for (const s of sp) if (!this.shown.has(s.id)) this.born[s.id] ??= now;
    const ps = panes();
    const due = this.due(now, sp, ps);

    if (due.size) this.refreshGit(due, cx);
    const prDue = this.prDue(now, sp, ps);

    if (prDue.size) this.refreshPR(prDue, cx);

    if (sp.some((s) => !this.shown.has(s.id))) cx.notify();
  }

  prDue(now, sp, ps) {
    if (!window().active) return new Set();
    const due = new Set();

    for (const s of sp) {
      const key = where(s, ps);
      const g = this.git[key];

      if (!g?.branch || g.detached || this.folded.has(JSON.parse(key)[0])) continue;

      if (now - (this.prChecked[key] ?? 0) > PR_FALLBACK) due.add(key);
    }

    return due;
  }

  // Places whose git could have changed: new ones (a new space, a cd), where a
  // command or an agent's turn just ended (a checkout, a commit, edits), those on
  // a machine that is back, and repos in view whose fallback is due.
  due(now, sp, ps) {
    // Moved there: what it knew of that place may be old.
    const at = {};

    for (const s of sp) at[s.id] = where(s, ps);
    const keys = new Set(Object.values(at).filter((k) => JSON.parse(k)[1]));
    const due = new Set([...keys].filter((k) => !(k in this.git)));

    for (const [id, k] of Object.entries(at)) if (this.at[id] && this.at[id] !== k && keys.has(k)) due.add(k);
    this.at = at;
    const spaceOf = {};

    for (const s of sp) for (const t of s.tabs ?? []) spaceOf[t.id] = s;
    const busy = {};

    for (const p of ps) {
      if (!p.terminal || !spaceOf[p.tab]) continue;
      busy[p.pane] = p.status === "working" || !(p.program?.shell || p.program?.agent);

      if (this.busy[p.pane] && !busy[p.pane]) this.sameRepo(at[spaceOf[p.tab].id], keys).forEach((k) => due.add(k));
    }

    this.busy = busy;

    for (const m of machines()) {
      const ready = m.layout === "ready";

      if (ready && this.ready[m.name] === false) for (const k of keys) if (JSON.parse(k)[0] === m.name) due.add(k);
      this.ready[m.name] = ready;
    }

    if (window().active) {
      for (const k of keys) {
        const asks = this.git[k] || this.unsure.has(k);

        if (asks && !this.folded.has(JSON.parse(k)[0]) && now - (this.checked[k] ?? 0) > FALLBACK) due.add(k);
      }
    }

    return due;
  }

  // `key` and the other places in its repo (a commit there moves their ahead/behind).
  sameRepo(key, keys) {
    const repo = this.git[key]?.repo;

    return [key, ...(repo ? [...keys].filter((k) => this.git[k]?.repo === repo) : [])];
  }

  refreshMachines(cx) {
    cx.spawn(async cx => {
      try { const r = await hc(["machine", "ls", "--json"]);

 if (r.code === 0) this.machines = (JSON.parse(r.stdout).machines ?? []).filter((m) => !m.temporary); } catch {}

      cx.notify();
    });
  }

  rebuilt(machine) {
    return machine?.state === "unreachable" && /^a different core answers there \("[^"]+"\)$/.test(machine.why ?? "");
  }

  reconnect(machine, cx) {
    const name = machine.name;

    if (this.reconnecting[name]?.busy) return;
    const state = this.reconnecting[name] ??= { machine, removed: false };
    state.busy = true;
    state.error = null;
    localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
    cx.notify();
    cx.spawn(async cx => {
      try {
        const ask = async args => {
          const r = await hc([...args, "--json"]);

          if (r.code !== 0) {
            let error;

            try { error = JSON.parse(r.stdout || r.stderr).error?.message; } catch {}

            throw new Error(error || r.stderr || r.stdout || "Couldn't connect.");
          }
        };

        if (!state.removed) {
          await ask(["machine", "rm", name]);
          state.removed = true;
          localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
        }

        const args = ["machine", "add"];

        if (machine.via) args.push("--via", machine.target);
        else args.push(machine.target);
        args.push("--name", name);

        if (machine.session) args.push("--session", machine.session);

        if (machine.temporary) args.push("--temp");
        await ask(args);
        this.folded.delete(name);
        localStorage.setItem("machines.folded", JSON.stringify([...this.folded]));
        delete this.reconnecting[name];
      } catch (e) {
        state.error = String(e.message ?? e);
        state.busy = false;
      }

      localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
      this.refreshMachines(cx);
      cx.notify();
    });
  }

  // One look at a time, each place once however often it was asked for meanwhile.
  refreshGit(keys, cx) {
    for (const k of keys) this.pending.add(k);

    if (this.refreshing) return;
    this.refreshing = true;
    cx.spawn(async (cx) => {
      while (this.pending.size) {
        const keys = [...this.pending];
        this.pending.clear();

        for (const key of keys) await this.check(key, cx);
      }

      const used = new Set(Object.values(this.git).filter(Boolean).map((g) => JSON.parse(g.repo)).filter(([on]) => !on).map(([, repo]) => repo));

      for (const repo of this.watching) if (!used.has(repo)) this.watching.delete(repo);
      this.refreshing = false;
      cx.notify();
    });
  }

  refreshPR(keys, cx) {
    for (const key of keys) {
      this.prPending.add(key);
      this.prChecked[key] = Date.now();
    }

    if (this.prRefreshing) return;
    this.prRefreshing = true;
    cx.spawn(async (cx) => {
      while (this.prPending.size) {
        const keys = [...this.prPending];
        this.prPending.clear();

        for (const key of keys) await this.checkPR(key);
      }

      this.prRefreshing = false;
      cx.notify();
    });
  }

  // One place's git: branch, counts and its repo.
  async check(key, cx) {
    const [on, cwd] = JSON.parse(key);
    this.checked[key] = Date.now();
    this.unsure.delete(key);

    try {
      // No optional locks: a status that touched the index would wake the watch again.
      // Writes nothing under .git (index lock, fsmonitor cookie): watch() would wake on it.
      const r = await exec("git", ["--no-optional-locks", "-c", "core.fsmonitor=false", "status", "--porcelain=v2", "--branch", "--untracked-files=all"], { cwd, on });

      if (r.code !== 0) {
        // Only git's own "no" is remembered as no repo; anything else is asked again.
        if (!/not a git repository/i.test(r.stderr)) this.unsure.add(key);
        this.git[key] = null;
        this.pr[key] = null;

        return;
      }

      // The repo's own .git folder names it; a worktree's top differs from it.
      const top = await exec("git", ["rev-parse", "--show-toplevel"], { cwd, on });
      const common = await exec("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd, on });
      const repo = common.stdout.trim();
      const name = repo.endsWith("/.git") ? base(repo.slice(0, -5)) : base(repo).replace(/\.git$/, "");
      const previous = this.git[key];

      const info = {
        name,
        branch: null,
        detached: false,
        oid: null,
        pull: 0,
        push: 0,
        conflicts: 0,
        staged: 0,
        unstaged: 0,
        untracked: 0,
        repo: JSON.stringify([on, repo]),
        linked: repo !== `${top.stdout.trim()}/.git`,
      };

      for (const line of r.stdout.split("\n")) {
        if (line.startsWith("# branch.head ")) {
          const branch = line.slice(14);
          info.detached = branch === "(detached)";
          info.branch = info.detached ? "detached" : branch;
        } else if (line.startsWith("# branch.oid ")) {
          const oid = line.slice(13);
          info.oid = oid;
        }
        else if (line.startsWith("# branch.ab ")) {
          const [a, b] = line.slice(12).split(" ");
          info.push = Math.max(parseInt(a, 10) || 0, 0);
          info.pull = Math.max(-(parseInt(b, 10) || 0), 0);
        } else if (line.startsWith("u ")) {
          info.conflicts += 1;
        } else if (line.startsWith("? ")) {
          info.untracked += 1;
        } else if (line.startsWith("1 ") || line.startsWith("2 ")) {
          const xy = line.split(" ")[1] ?? "..";

          if (xy[0] !== ".") info.staged += 1;

          if (xy[1] !== ".") info.unstaged += 1;
        }
      }

      if (info.detached && /^[0-9a-f]{7,40}$/i.test(info.oid ?? "")) info.branch = info.oid.slice(0, 7);

      this.git[key] = info;

      if (!on) this.watch(repo, cx);
      const changed = !previous || ["branch", "oid", "pull", "push", "conflicts", "staged", "unstaged", "untracked"].some((field) => previous[field] !== info[field]);

      if (changed) {
        if (previous?.branch !== info.branch || previous?.detached !== info.detached) {
          this.pr[key] = null;
        }

        if (info.branch && !info.detached) this.refreshPR(new Set([key]), cx);
      }
    } catch {
      // Couldn't ask (the machine is away): keep what it showed, look again later.
      this.git[key] ??= null;
      this.unsure.add(key);
    }
  }

  async checkPR(key) {
    const g = this.git[key];

    if (!g?.branch || g.detached) {
      this.pr[key] = null;

      return;
    }

    const [on, cwd] = JSON.parse(key);
    const branch = g.branch;

    try {
      const r = await exec("gh", ["pr", "view", "--json", "number,state,isDraft,reviewDecision,statusCheckRollup"], { cwd, on });

      if (this.git[key]?.branch !== branch) return;

      if (r.code !== 0) {
        if (/no pull requests found/i.test(r.stderr ?? "")) this.pr[key] = null;

        return;
      }

      let raw;

      try { raw = JSON.parse(r.stdout); } catch { return; }

      if (!raw || !Number.isInteger(raw.number)) {
        return;
      }

      const checks = summarizeChecks(raw.statusCheckRollup);
      let state = String(raw.state ?? "OPEN").toLowerCase();

      if (state === "open") {
        if (raw.isDraft) state = "draft";
        else if (checks.state === "fail") state = "checks_failed";
        else if (checks.state === "pending") state = "checks_pending";
      }

      this.pr[key] = {
        number: raw.number,
        state,
        review: raw.reviewDecision || null,
        checks,
      };
    } catch { /* Keep the previous row and try again on the next sweep. */ }
  }

  watch(repo, cx) {
    if (this.watching.has(repo)) return;
    this.watching.add(repo);
    cx.spawn(async (cx) => {
      try {
        while (this.watching.has(repo)) {
          await watchFolder(repo);
          const mine = JSON.stringify([null, repo]);

          if (this.watching.has(repo)) this.refreshGit(Object.keys(this.git).filter((k) => this.git[k]?.repo === mine), cx);
        }
      } catch { this.watching.delete(repo); }
    });
  }

  menu(w) {
    // A popup is as tall as its items; height is only the most.
    openOverlay({ mod: "menu", kind: "popup", width: 200, height: 260, props: { tab: "space", target: { id: w.id } } });
  }

  // Spaces in order, each worktree space moved under its main checkout's.
  ordered() {
    const sp = spaces(), ps = panes();
    const ready = (w) => this.shown.has(w.id) || where(w, ps) in this.git || Date.now() - (this.born[w.id] ??= Date.now()) > 1500;

    for (const w of sp) if (!this.shown.has(w.id) && ready(w)) this.shown.add(w.id);

    const list = sp.map((w, i) => {
      const key = where(w, ps);

      return { w, i, key, g: this.git[key] ?? null };
    }).filter((r) => this.shown.has(r.w.id));

    const mains = new Set(list.filter((r) => r.g && !r.g.linked).map((r) => r.g.repo));
    const nested = (r) => r.g?.linked && mains.has(r.g.repo);
    const out = [];
    const placed = new Set(); // repos whose worktrees are listed (under the first of its spaces)

    for (const r of list) {
      if (nested(r)) continue;
      out.push({ ...r, tree: null });

      if (!r.g || r.g.linked || placed.has(r.g.repo)) continue;
      placed.add(r.g.repo);
      const kids = list.filter((k) => nested(k) && k.g.repo === r.g.repo);
      kids.forEach((k, n) => out.push({ ...k, tree: n === kids.length - 1 ? "└─" : "├─" }));
    }

    return out;
  }

  // The rows, under a header per machine once one isn't this computer.
  grouped(t, collapsed) {
    const rows = this.ordered();
    const draw = (r) => (collapsed ? this.compact(r, t) : this.row(r, t));
    const remote = [...new Set([...rows.map(r => r.w.machine).filter(Boolean), ...this.machines.map(m => m.name), ...Object.keys(this.reconnecting)])].sort();

    const loading = m => {
      const layout = machines().find(k => k.name === m)?.layout;

      return layout === "loading" || (!layout && this.machines.some(k => k.name === m && k.state === "connected"))
        || spaces().some(s => (s.machine ?? null) === m && !this.shown.has(s.id));
    };

    const loadingRow = m => div().id(`machine-loading-${m ?? "local"}`).h(28).flex_none().px(8).text_size(12).text_color(t.dim).child(collapsed ? "…" : "Loading…");

    if (!remote.length) return loading(null) && !rows.length ? [loadingRow(null)] : rows.map(draw);
    const machineNames = [null, ...remote];

    return machineNames.flatMap((m) => {
      const mine = rows.filter((r) => (r.w.machine ?? null) === m);
      const repair = this.reconnecting[m];
      const machine = this.machines.find(k => k.name === m) ?? repair?.machine;
      const connected = !m || machine?.state === "connected";
      const rebuilt = this.rebuilt(machine) || !!repair;
      const folded = this.folded.has(m);

      const head = h_flex().id(`machine-${m ?? "local"}`).h(26).flex_none().px(collapsed ? 2 : 8).gap(7).items_center().text_size(11).text_color(t.dim)
        .cursor_pointer().hover(s => s.bg(t.hover))
        .on_click((_e, cx) => {
          if (folded) this.folded.delete(m);
          else this.folded.add(m);
          localStorage.setItem("machines.folded", JSON.stringify([...this.folded]));
          cx.notify();
        })
        .child(svg(`mods/workspace-chrome/${m ? "server" : "monitor"}.svg`).size(13).flex_none())
        .when(!collapsed, el => el.child(div().flex_1().truncate().child(m ?? "This computer"))
          .when(!connected && !rebuilt, el => el.child(div().flex_none().child((machine?.state ?? "asleep").replace(/_/g, " "))))
          .when(rebuilt, el => el.child(h_flex().flex_none().gap(3).items_center()
            .child(div().max_w(140).truncate().child(repair?.error || "rebuilt ·"))
            .child(div().id(`machine-connect-${m}`).text_color(repair?.error ? t.blocked : t.muted)
              .hover(s => s.text_color(t.foreground))
              .tooltip(repair?.error || "This machine was rebuilt or replaced. Click to connect to the new one.")
              .on_click((_e, cx) => { cx.stop_propagation(); this.reconnect(machine, cx); })
              .child(repair?.busy ? "Connecting…" : "Connect"))))
          .when(connected, el => el.child(div().id(`machine-add-${m ?? "local"}`).flex_none().px(4).rounded(4).hover(s => s.bg(t.hover).text_color(t.foreground))
            .on_click((_e, cx) => { cx.stop_propagation(); run("space.new", { machine: m ?? "" }); }).child("+")))
          .child(div().size(6).rounded(3).flex_none().bg(connected ? t.ansi2 : t.dim))
          .child(svg(`mods/workspace-chrome/chevron-${folded ? "right" : "down"}.svg`).size(11).flex_none()));

      const empty = h_flex().id(`machine-new-${m ?? "local"}`).h(28).flex_none().px(8).gap(7).items_center().rounded(7)
        .text_size(12).text_color(t.dim).hover(s => s.bg(t.hover).text_color(t.foreground))
        .on_click(() => run("space.new", { machine: m ?? "" }))
        .child(svg("mods/workspace-chrome/plus.svg").size(12)).when(!collapsed, el => el.child("New space there"));

      if (!collapsed && rebuilt) return [head];

      return [head, ...(folded ? [] : mine.length ? mine.map(draw) : [loading(m) ? loadingRow(m) : empty])];
    });
  }

  gitCounts(g, t) {
    const parts = [
      [g.pull, `⇣${g.pull}`, t.dim],
      [g.push, `⇡${g.push}`, t.dim],
      [g.conflicts, `~${g.conflicts}`, t.blocked],
      [g.staged, `+${g.staged}`, t.dim],
      [g.unstaged, `!${g.unstaged}`, t.dim],
      [g.untracked, `?${g.untracked}`, t.dim],
    ].filter(([count]) => count > 0);

    return h_flex().flex_none().gap(5).items_center().text_color(t.dim)
      .children(parts.map(([, text, color]) => div().flex_none().text_color(color).child(text)));
  }

  prRow(pr, tree, t) {
    const checks = pr.state === "merged" || pr.state === "closed" ? null : checksLabel(pr.checks);
    const review = pr.state === "merged" || pr.state === "closed" ? null : reviewLabel(pr.review);
    const details = [checks, review].filter(Boolean);

    const color = pr.state === "merged" ? t.ansi5
      : pr.state === "closed" || pr.state === "draft" ? t.dim
        : pr.state === "checks_failed" ? t.blocked
          : pr.state === "checks_pending" ? t.working
            : t.ansi2;

    return h_flex().h(16).flex_none().min_w(0).items_center().gap(5).pl(tree ? 44 : 27).text_size(11).text_color(t.dim)
      .child(div().flex_none().text_color(color).child(prGlyph(pr.state)))
      .child(div().flex_none().child(`#${pr.number}${prLabel(pr.state) ? ` ${prLabel(pr.state)}` : ""}`))
      .when(details.length > 0, (el) => el.child(div().flex_none().child("·")))
      .children(details.map((detail, i) => h_flex().flex_none().gap(5).children([
        i > 0 ? div().child("·") : null,
        div().flex_none().child(detail),
      ].filter(Boolean))));
  }

  row({ w, i, g, tree, key }, t) {
    const on = w.active;
    const pr = this.pr[key] ?? null;
    const colors = shared("space.colors") ?? {};
    const color = colors[w.id] ?? "ansi6";
    const fill = color.startsWith("#") ? color : (MARK[color] ?? t[color]);
    const extra = (g ? 1 : 0) + (pr ? 1 : 0);

    const header = h_flex().h(16).flex_none().gap(9).items_center()
      .when(Boolean(tree), el => el.pl(22).child(svg("mods/workspace-chrome/branch.svg").size(13).text_color(t.dim)))
      .when(!tree, el => el.child(h_flex().size(18).flex_none().rounded(5).bg(fill).items_center().justify_center().text_size(10.5).font_bold().text_color("#ffffff").child([...w.name][0]?.toUpperCase() ?? "?")))
      .child(div().flex_shrink(0).max_w(150).truncate().text_color(t.foreground).child(w.name))
      .when(Boolean(w.status), el => el.child(div().flex_none().text_color(tone(t, w.status)).child(glyph(w.status))));

    return v_flex()
      .relative()
      .id(`space-${w.id}`)
      .px(8)
      .h(rowHeight({ tree, extra }))
      .flex_none()
      .justify_center()
      .rounded(8)
      .when(on, (el) => el.bg(t.selected))
      .when(!on, (el) => el.hover((s) => s.bg(t.hover)))
      .when(this.pressed === i && this.over !== i, (el) => el.opacity(0.5))
      .when(this.pressed !== null && this.over === i && this.pressed !== i, (el) => el.child(
        div().absolute().left(0).right(0).h(2).bg(t.accent)
          .when(this.pressed < i, line => line.bottom(0))
          .when(this.pressed > i, line => line.top(0)),
      ))
      .on_mouse_down("left", () => {
        this.pressed = i;
        this.over = i;
      })
      .on_mouse_move((_e, cx) => {
        const source = spaces()[this.pressed];
        const over = source && (source.machine ?? null) === (w.machine ?? null) ? i : null;

        if (this.pressed !== null && this.over !== over) {
          this.over = over;
          cx.notify();
        }
      })
      .on_mouse_up("left", (_e, cx) => {
        const from = this.pressed;
        const over = this.over;
        this.pressed = null;
        this.over = null;

        if (from !== null && over === i && from !== i) run("space.move", { id: spaces()[from].id, index: i + 1 });
        else if (from === i) run("space.select", { id: w.id });
        cx.notify();
      })
      .on_mouse_down("right", () => this.menu(w))
      .children([
        header,
        g ? h_flex().h(16).flex_none().min_w(0).items_center().gap(6).pl(tree ? 44 : 27).text_size(11.5)
          .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).child(g.branch ?? "detached"))
          .child(this.gitCounts(g, t)) : null,
        pr ? this.prRow(pr, tree, t) : null,
      ].filter(Boolean));
  }

  compact({ w, i }, t) {
    return h_flex()
      .id(`space-${w.id}`)
      .h(26)
      .flex_none()
      .justify_center()
      .gap(4)
      .when(w.active, (el) => el.bg(t.raised))
      .hover((s) => s.bg(t.hover))
      .on_click(() => run("space.select", { id: w.id }))
      .child(div().text_color(w.active ? t.foreground : t.muted).child(String(i + 1)))
      .child(div().text_color(tone(t, w.status)).child(glyph(w.status)));
  }

  render() {
    const t = theme();
    const collapsed = narrow();
    const palette = ["ansi6", "ansi3", "ansi4", "ansi5", "ansi2", "ansi1"];
    const sp = spaces();
    const ids = new Set(sp.map(p => p.id));
    const kept = Object.fromEntries(Object.entries(shared("space.colors") ?? {}).filter(([id]) => ids.has(id)));
    let changed = Object.keys(kept).length !== Object.keys(shared("space.colors") ?? {}).length;

    for (const p of sp) {
      if (kept[p.id] || p.name === "~") continue;
      const uses = c => Object.values(kept).filter(v => v === c).length;
      kept[p.id] = palette.reduce((best, c) => uses(c) < uses(best) ? c : best);
      changed = true;
    }

    if (changed) setShared("space.colors", kept);

    return v_flex().size_full().min_h(0).bg(t.chrome).text_size(13)
      .child(h_flex().h(31).pl(16).pr(10).items_center().justify_between().text_size(11.5).text_color(t.dim)
        .when(!collapsed, el => el.child("Spaces"))
        .child(div().id("space-new").size(26).flex_none().flex().items_center().justify_center().rounded(6).hover(s => s.bg(t.hover).text_color(t.foreground))
          .on_click(() => run("space.new")).child(svg("mods/workspace-chrome/plus.svg").size(14))))
      .child(v_flex().flex_1().min_h(0).px(8).pb(14).overflow_y_scrollbar().mode("always")
        .on_mouse_up("left", (_e, cx) => { this.pressed = null; cx.notify(); })
        .children(this.grouped(t, collapsed)));
  }
}
