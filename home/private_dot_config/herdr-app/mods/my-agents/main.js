// Agents in grouped or priority views; parents take their most urgent sub-agent's place.
// A viewed done agent stays in Done until left.

import { View, div, image, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, terminals, panes, focused, spaces, machines, exec, run, theme, shared, setShared, setAgentOrder, openOverlay, closeOverlay, props, window, layout } from "herdr";

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

// To the rail (on macOS wide enough for the traffic lights), or back to the width it had.
function toggleSidebar() {
  const width = find(layout(), "sidebar")?.size?.px;

  if (!narrow()) setShared("sidebar.width", width);
  // Mods edited before the rail went by width still read the flag.
  setShared("sidebar.collapsed", !narrow());
  run("layout.resize", { id: "sidebar", px: narrow() ? (shared("sidebar.width") ?? 268) : window()?.platform === "macos" ? 76 : 44 });
}

const clean = (s) => (s ?? "").replace(/^[^\p{L}\p{N}]+/u, "").trim();

// The pool's source of truth is ~/.local/lib/herdr-pane-labels/herdr-aliases.sh.
const ALIAS_COLORS = [
  "amber", "aqua", "azure", "beige", "black", "blue", "brown", "coral",
  "cream", "cyan", "gold", "gray", "green", "ivory", "jade", "khaki",
  "lilac", "lime", "navy", "ochre", "olive", "pink", "red", "teal",
];

const ALIAS_ANIMALS = [
  "akita", "ant", "baiji", "barb", "bat", "bear", "bison", "boar", "bongo", "booby",
  "camel", "carp", "cat", "coati", "cobra", "coral", "cow", "crab", "crane", "crow",
  "deer", "dhole", "dingo", "dodo", "dog", "dogo", "duck", "eagle", "eel", "elk",
  "emu", "finch", "fish", "fluke", "fly", "fossa", "fox", "frog", "gar", "gecko",
  "goat", "goose", "hare", "heron", "horse", "human", "hyena", "ibex", "ibis", "kiwi",
  "koala", "krill", "kudu", "lemur", "liger", "lion", "llama", "loach", "lynx", "macaw",
  "mole", "molly", "moose", "moth", "mouse", "mule", "newt", "okapi", "olm", "otter",
  "panda", "pig", "pika", "polar", "prawn", "pug", "quail", "quoll", "rat", "raven",
  "robin", "seal", "shark", "sheep", "skunk", "sloth", "snail", "snake", "squid", "stoat",
  "swan", "tetra", "tiger", "toad", "tuna", "wasp", "whale", "wolf", "worm", "zebra", "zebu",
];

const ALIAS_POOL = ALIAS_COLORS.length * ALIAS_ANIMALS.length;

const ALIAS_COLOR_SET = new Set(ALIAS_COLORS);

const ALIAS_ANIMAL_SET = new Set(ALIAS_ANIMALS);

function isPoolAlias(name) {
  const parts = name?.split("-") ?? [];

  return parts.length === 2 && ALIAS_COLOR_SET.has(parts[0]) && ALIAS_ANIMAL_SET.has(parts[1]);
}

// FNV-1a is stable in the mod and intentionally does not reproduce POSIX cksum.
function aliasOffset(seed) {
  let hash = 2166136261;

  for (let i = 0; i < seed.length; i += 1) {
    hash ^= seed.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }

  return (hash >>> 0) % ALIAS_POOL;
}

function aliasCandidates(seed) {
  const offset = aliasOffset(seed);

  return Array.from({ length: ALIAS_POOL }, (_, step) => {
    const position = (offset + step) % ALIAS_POOL;

    return `${ALIAS_COLORS[Math.floor(position / ALIAS_ANIMALS.length)]}-${ALIAS_ANIMALS[position % ALIAS_ANIMALS.length]}`;
  });
}

const base = (path) => path?.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? "";

const machineOf = (a) => (a.address.includes("/") ? a.address.split("/")[0] : null);

// The agent's own name for its work. OpenCode prefixes its terminal title; its report doesn't.
function agentTask(terminal) {
  const task = clean(terminal?.report?.title ?? terminal?.title).replace(/^OC \| /, "");
  const program = terminal?.program;
  const telling = task && task !== program?.name && task.toLowerCase() !== program?.key && !/^[~/]|^[A-Za-z]:\\/.test(task) && !task.includes("@");

  return telling ? task : null;
}

// This mod renames tabs to their agents' aliases; any other given name came from a person.
function handName(tab, program) {
  if (!tab?.named || tab.name === program || tab.name.split(" · ").every((part) => part === "~" || isPoolAlias(part))) return null;

  return tab.name;
}

// A generated worktree name says little beyond its middle words.
function worktreeLabel(name, project) {
  const short = name.replace(/^worktree-(.+)-[0-9a-f]{4}$/, "$1");
  const prefix = `${project}-`;

  return short.startsWith(prefix) ? short.slice(prefix.length) : short;
}

const RANK = { blocked: 4, done: 3, working: 2, idle: 1 };

const TAB_NAMES_KEY = "my-agents.tabNames";

function decodeTabName(value) {
  const encoded = JSON.stringify(value);

  if (encoded?.startsWith('"')) return { space: null, machine: null, name: JSON.parse(encoded), migrated: true };

  if (!encoded?.startsWith("{") || Array.isArray(value)) return null;

  const name = JSON.stringify(value.name);
  const space = JSON.stringify(value.space);
  const hasMachine = Object.prototype.hasOwnProperty.call(value, "machine");
  const machine = hasMachine ? JSON.stringify(value.machine) : "null";

  if (!name?.startsWith('"') || !(space === "null" || space?.startsWith('"')) || !(machine === "null" || machine?.startsWith('"'))) return null;

  return {
    space: space === "null" ? null : JSON.parse(space),
    machine: machine === "null" ? null : JSON.parse(machine),
    name: JSON.parse(name),
    migrated: !hasMachine,
  };
}

// A sub-agent without a pane isn't in agents(): its raw word, error counting as
// blocked. It's never done: it reports to its parent, and the parent's done is the news.
const kidStatus = (k, listed) => {
  const s = listed.get(k.address) ?? k.status;

  return s === "error" ? "blocked" : s === "done" ? "idle" : s;
};

const SORTS = [
  { id: "priority", label: "Priority", icon: "clock" },
  { id: "grouped", label: "Grouped by space", icon: "layers" },
  { id: "project", label: "Grouped by project", icon: "git-branch" },
];

const sortOf = () => SORTS.find((s) => s.id === shared("agents.sort")) ?? SORTS[0];

const SECTION = { 4: "Needs you", 3: "Done", 2: "Working", 1: "Idle" };

const SECTION_STATUS = { 4: "blocked", 3: "done", 2: "working" };

function duration(ms) {
  const m = Math.floor(ms / 60000);

  if (m < 1) return "<1m";

  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);

  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

// The agent's icon from the app's program table: a one-color glyph or a picture.
function icon(p, size, color) {
  if (!p?.icon) return null;

  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

function machineAsset(machine) {
  return !machine || /mbp|mac/i.test(machine) ? "laptop" : "server";
}

export default class Agents extends View {
  init(_props, cx) {
    if (props()?.sortMenu) return;
    this.folded = new Set();
    // Each agent's last state and when it changed (ms), kept across restarts.
    this.changed = JSON.parse(localStorage.getItem("changed") ?? "{}");
    this.pendingPins = JSON.parse(localStorage.getItem("pins") ?? "[]");

    if (!this.pendingPins.length) localStorage.removeItem("pins");
    this.migratingPins = new Set();
    this.alias = new Map();
    this.aliases = new Map();
    const storedTabNames = JSON.parse(JSON.stringify(shared(TAB_NAMES_KEY) ?? {}));
    this.tabNames = {};
    const storedTabEntries = JSON.stringify(storedTabNames).startsWith("{") ? Object.entries(storedTabNames) : [];
    this.tabNamesChanged = storedTabEntries.length !== Object.keys(storedTabNames).length;

    for (const [id, value] of storedTabEntries) {
      const decoded = decodeTabName(value);

      if (!decoded) this.tabNamesChanged = true;
      else {
        this.tabNames[id] = { space: decoded.space, machine: decoded.machine, name: decoded.name };

        if (decoded.migrated) this.tabNamesChanged = true;
      }
    }

    this.pendingTabRenames = new Map();
    this.sentTabRenames = new Map();
    this.blockedTabRenames = new Map();
    this.tabRenameFlushQueued = false;
    this.origin = new Map();
    this.originFolders = new Map();
    this.originPending = new Set();
    this.originRefreshing = false;
    cx.timer.every(30000, (cx) => cx.notify());
  }

  // Stamps agents whose state changed. Done and idle count as one: looking at a
  // finished agent turns done into idle, and looking isn't the agent doing anything.
  track(list, now) {
    let dirty = false;

    for (const a of list) {
      const s = a.status === "done" ? "idle" : a.status;

      if (this.changed[a.address]?.s === s) continue;
      this.changed[a.address] = { s, at: now };
      dirty = true;
    }

    if (!dirty) return;
    // Gone and old: the list alone is empty right after a start.
    const listed = new Set(list.map((a) => a.address));

    for (const [k, c] of Object.entries(this.changed)) if (!listed.has(k) && now - c.at > 30 * 86400000) delete this.changed[k];
    localStorage.setItem("changed", JSON.stringify(this.changed));
  }

  // Keep offline pins until their terminal returns, and keep each pending until
  // core echoes the label so a failed write doesn't erase the old pin.
  migratePins(all) {
    const listed = new Map(all.filter((t) => t.state === "live").map((t) => [t.address, t]));

    const pending = this.pendingPins.filter((address) => {
      const terminal = listed.get(address);

      if (!terminal) return true;

      if (terminal.labels?.["herdr.pinned"]) return false;

      if (!this.migratingPins.has(address)) {
        this.migratingPins.add(address);
        run("terminal.pin", { terminal: address, pinned: true });
      }

      return true;
    });

    if (pending.length === this.pendingPins.length) return;
    this.pendingPins = pending;

    if (pending.length) localStorage.setItem("pins", JSON.stringify(pending));
    else localStorage.removeItem("pins");
  }

  since(a) {
    return this.changed[a.address]?.at ?? 0;
  }

  assignAliases(rows, spaceList, terminalList) {
    const machines = new Map(spaceList.map((space) => [space.id, space.machine ?? ""]));

    const used = new Set();

    const aliases = new Map();

    const liveAliases = new Map(terminalList
      .filter((terminal) => terminal.state === "live" && isPoolAlias(terminal.name))
      .map((terminal) => [terminal.address, terminal.name]));

    for (const row of rows) {
      const alias = liveAliases.get(row.address);

      if (!alias || used.has(alias)) continue;
      this.alias.set(row.address, alias);
      aliases.set(row.address, alias);
      used.add(alias);
    }

    for (const row of rows) {
      const alias = this.alias.get(row.address);

      if (!alias || used.has(alias)) continue;
      aliases.set(row.address, alias);
      used.add(alias);
    }

    for (const row of rows) {
      if (aliases.has(row.address)) continue;
      const machine = machines.get(row.space) ?? (row.address.includes("/") ? row.address.split("/")[0] : "");
      const seed = `${machine}/${row.address}`;
      const alias = aliasCandidates(seed).find((candidate) => !used.has(candidate));

      if (!alias) continue;
      this.alias.set(row.address, alias);
      aliases.set(row.address, alias);
      used.add(alias);
    }

    this.aliases = aliases;
  }

  syncTabNames(spaceList, paneList, agentList, cx) {
    const tabs = spaceList.flatMap((space) => space.tabs);
    const liveTabs = new Set(tabs.map((tab) => tab.id));
    const tabSpaces = new Map(spaceList.flatMap((space) => space.tabs.map((tab) => [tab.id, space])));
    const readyMachines = new Set(machines().filter((machine) => machine.layout === "ready").map((machine) => machine.name ?? null));
    const machineReady = (entry) => readyMachines.has(entry.machine ?? null);

    const agentsByPane = new Map(agentList.map((agent) => [agent.pane, agent]));

    for (const id of Object.keys(this.tabNames)) {
      const space = tabSpaces.get(id);

      if (space) {
        const machine = space.machine ?? null;

        if (this.tabNames[id].space !== space.id || this.tabNames[id].machine !== machine) {
          this.tabNames[id].space = space.id;
          this.tabNames[id].machine = machine;
          this.tabNamesChanged = true;
        }
      } else if (machineReady(this.tabNames[id])) {
        delete this.tabNames[id];
        this.tabNamesChanged = true;
      }
    }

    for (const [id, pending] of this.pendingTabRenames) {
      if (!liveTabs.has(id) && machineReady(pending)) this.pendingTabRenames.delete(id);
    }

    for (const [id, sent] of this.sentTabRenames) {
      const tab = tabs.find((candidate) => candidate.id === id);

      if (!tab) {
        if (machineReady(sent)) this.sentTabRenames.delete(id);
        continue;
      }

      const space = tabSpaces.get(id);
      const machine = space.machine ?? null;
      const ownedName = this.tabNames[id]?.name;
      const owned = ownedName === tab.name;

      if (sent.name === "" && (!tab.named || tab.name !== ownedName)) {
        delete this.tabNames[id];
        this.tabNamesChanged = true;
        this.sentTabRenames.delete(id);
        this.blockedTabRenames.delete(id);
      } else if (tab.name === sent.name) {
        this.tabNames[id] = { space: space.id, machine, name: sent.name };
        this.tabNamesChanged = true;
        this.sentTabRenames.delete(id);
        this.blockedTabRenames.delete(id);
      } else if (tab.named && !owned) this.sentTabRenames.delete(id);
      else {
        sent.renders += 1;

        if (sent.renders >= 20) {
          this.sentTabRenames.delete(id);
          this.blockedTabRenames.set(id, { space: space.id, machine, name: sent.name });
        }
      }
    }

    for (const [id, blocked] of this.blockedTabRenames) {
      const tab = tabs.find((candidate) => candidate.id === id);

      if (!tab) {
        if (machineReady(blocked)) this.blockedTabRenames.delete(id);
        continue;
      }

      const space = tabSpaces.get(id);

      if (tab.name === blocked.name) {
        this.tabNames[id] = { space: space.id, machine: space.machine ?? null, name: blocked.name };
        this.tabNamesChanged = true;
        this.blockedTabRenames.delete(id);
      } else if (tab.named && this.tabNames[id]?.name !== tab.name) this.blockedTabRenames.delete(id);
    }

    for (const tab of tabs) {
      const panesInTab = paneList.filter((pane) => pane.tab === tab.id && pane.terminal);
      const agentPanes = panesInTab.filter((pane) => agentsByPane.has(pane.pane));

      const space = tabSpaces.get(tab.id);
      const machine = space.machine ?? null;
      const owned = this.tabNames[tab.id]?.name === tab.name;
      const sent = this.sentTabRenames.get(tab.id);
      const blocked = this.blockedTabRenames.get(tab.id);

      if (!agentPanes.length) {
        if (blocked && blocked.name !== "") this.blockedTabRenames.delete(tab.id);

        if (owned && !sent && (!blocked || blocked.name !== "") && machineReady({ machine })) {
          this.pendingTabRenames.set(tab.id, { space: space.id, machine, name: "" });
        }

        continue;
      }

      const intended = panesInTab.map((pane) => {
        const agent = agentsByPane.get(pane.pane);

        return agent ? this.aliases.get(agent.address) ?? "~" : "~";
      }).join(" · ");

      if (blocked && blocked.name !== intended) this.blockedTabRenames.delete(tab.id);

      if ((!tab.named || owned) && tab.name !== intended && !sent && (!blocked || blocked.name !== intended) && machineReady({ machine })) {
        this.pendingTabRenames.set(tab.id, { space: space.id, machine, name: intended });
      }
    }

    this.flushTabRenames(cx);
  }

  flushTabRenames(cx) {
    if (this.tabRenameFlushQueued || (!this.pendingTabRenames.size && !this.tabNamesChanged)) return;

    this.tabRenameFlushQueued = true;
    cx.spawn(async () => {
      const renames = [...this.pendingTabRenames.entries()];
      this.pendingTabRenames.clear();
      let changed = this.tabNamesChanged;
      this.tabNamesChanged = false;

      try {
        for (const [id, pending] of renames) {
          const { name, space, machine } = pending;

          run("tab.rename", { id, name });
          this.sentTabRenames.set(id, { space, machine, name, renders: 0 });
        }

        if (changed) setShared(TAB_NAMES_KEY, this.tabNames);
      } finally {
        this.tabRenameFlushQueued = false;
      }
    });
  }

  refreshOrigins(spaceList, cx) {
    for (const space of spaceList) {
      if (!space.folder) continue;
      const key = JSON.stringify([space.machine ?? null, space.folder]);
      const cached = this.originFolders.get(key);

      if (cached) {
        this.origin.set(space.id, { ...cached, folder: space.folder, machine: space.machine ?? null });
      } else this.originPending.add(key);
    }

    if (!this.originPending.size || this.originRefreshing) return;
    this.originRefreshing = true;
    cx.spawn(async (cx) => {
      const attempted = new Set();
      let changed = false;

      while (this.originPending.size) {
        const keys = [...this.originPending].filter((key) => !attempted.has(key));
        this.originPending.clear();

        if (!keys.length) break;

        for (const key of keys) {
          if (this.originFolders.has(key)) continue;
          attempted.add(key);
          const [machine, folder] = JSON.parse(key);
          let result = { main: null, linked: false };
          let complete = false;

          try {
            const top = await exec("git", ["rev-parse", "--show-toplevel"], { cwd: folder, on: machine });
            const common = await exec("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd: folder, on: machine });
            complete = true;
            const topPath = top.stdout.trim();
            const commonPath = common.stdout.trim();

            if (top.code === 0 && common.code === 0 && topPath && commonPath) {
              const main = commonPath.endsWith("/.git") ? commonPath.slice(0, -5) : commonPath;
              result = { main, linked: main !== topPath };
            }
          } catch {
            // A missing or unreachable space has no origin until it is seen again.
          }

          if (!complete) continue;
          this.originFolders.set(key, result);
          changed = true;

          for (const current of spaces()) {
            const currentKey = JSON.stringify([current.machine ?? null, current.folder]);

            if (currentKey === key) this.origin.set(current.id, { ...result, folder: current.folder, machine: current.machine ?? null });
          }
        }
      }

      this.originRefreshing = false;

      if (changed) cx.notify();
    });
  }

  originLabel(agent, spaceList) {
    const space = spaceList.find((candidate) => candidate.id === agent.space);
    const info = this.origin.get(agent.space);

    if (!space || !info || info.folder !== space.folder || !info.linked || !info.main) return null;

    return spaceList.find((candidate) => candidate.machine === space.machine && candidate.folder === info.main)?.name ?? base(info.main);
  }

  // Looking at a done agent makes it idle; it stays with Done until you leave
  // it rather than drop away under you. Any other change moves it at once.
  hold(list) {
    const cur = list.find((a) => a.focused);
    const same = cur && cur.address === this.held?.address;

    // Arriving, or any change but done turning idle, sets what it was.
    if (!same || cur.status !== "idle") this.held = cur ? { address: cur.address, rank: RANK[cur.status] ?? 0 } : null;
  }

  rank(a) {
    const sawDone = a.address === this.held?.address && this.held.rank === RANK.done && a.status === "idle";

    return sawDone ? RANK.done : RANK[a.status] ?? 0;
  }

  sortMenu(t) {
    const on = sortOf().id;

    return v_flex()
      .w_full()
      .p(5)
      .bg(t.popover)
      .text_size(12.8)
      .child(div().px(8).pt(4).pb(6).text_size(11).text_color(t.dim).child("Sort agents"))
      .children(SORTS.map((s) => h_flex()
        .id(`sort-${s.id}`)
        .h(31)
        .px(8)
        .gap(9)
        .rounded(7)
        .items_center()
        .text_color(t.foreground)
        .hover((el) => el.bg(t.hover))
        .on_click(() => {
          setShared("agents.sort", s.id);
          closeOverlay(props().overlay);
        })
        .child(svg(`mods/workspace-chrome/${s.icon}.svg`).size(14).flex_none().text_color(t.muted))
        .child(div().flex_1().child(s.label))
        .when(s.id === on, (el) => el.child(svg("mods/workspace-chrome/check.svg").size(14).flex_none().text_color(t.foreground)))));
  }

  peek(addr) {
    run("terminal.peek", { terminal: addr });
  }

  // Live sub-agents of `addr`, depth first, each with the tree lines in front of it.
  tree(all, addr, lead = []) {
    const kids = all.filter((k) => k.parent === addr && k.state === "live");

    return kids.flatMap((k, i) => {
      const last = i === kids.length - 1;

      return [
        { t: k, lines: [...lead, last ? "└" : "├"] },
        ...this.tree(all, k.address, [...lead, last ? "" : "│"]),
      ];
    });
  }

  subRow(t, s, shown, compact) {
    const k = s.t;
    const st = kidStatus(k, this.listed);
    const pic = icon(k.program, 14, t.foreground);
    const alias = this.aliases.get(k.address);
    // hc-run names a child with its alias; skip a name the alias column already shows.
    const name = [agentTask(k), k.name, k.template, k.program?.name, k.address].find((s) => s && s !== alias);
    const on = k.address === shown;

    return h_flex()
      .id(`sub-${k.address}`)
      .pl(39)
      .pr(8)
      .rounded(8)
      .h(26)
      .flex_none()
      .gap(0)
      .items_center()
      .text_size(12.5)
      .when(on, (el) => el.bg(t.raised))
      .hover((s) => s.bg(t.hover))
      .on_click(() => this.peek(k.address))
      .children(s.lines.map(l => div().self_start().mt(-4).w(9).h(17).mr(4).flex_none()
        .when(Boolean(l), el => el.border_l(1.5).border_color(t.input))
        .when(l === "└" || l === "├", el => el.border_b(1.5).rounded_bl(6))))
       .when(Boolean(pic), el => el.child(div().mr(8).child(pic)))
       .child(div().mr(8).flex_none().text_color(t.muted).child(alias ?? ""))
       .child(div().flex_1().truncate().text_color(on ? t.foreground : t.muted).child(name ?? ""))
       .child(this.status(t, { status: st }, compact));
  }

  stateGlyph(t, status) {
    if (status === "working") return svg("mods/workspace-chrome/spinner.svg").size(12).mx(1).flex_none().text_color(t.working).spin(900);

    const glyph = { blocked: "!", done: "✓", idle: "○" }[status] ?? "?";

    return div().w(14).flex_none().text_size(13).font_semibold().text_color(t[status] ?? t.unknown).text_center().child(glyph);
  }

  // compact: a ! for blocked where a header already says "Needs you".
  status(t, a, compact = false) {
    if (a.status === "working") return svg("mods/workspace-chrome/spinner.svg").size(12).mx(1).flex_none().text_color(t.working).spin(900);

    if (a.status === "blocked" && compact) return div().size(14).flex_none().rounded(4).bg(t.blocked + "26").text_size(10.5).font_bold().text_color(t.blocked).flex().items_center().justify_center().child("!");

    if (a.status === "blocked") return div().flex_none().px(6).h(18).rounded(5).bg(t.blocked + "26").text_size(10.5).font_semibold().text_color(t.blocked).flex().items_center().child("Needs you");

    if (a.status === "done") return this.stateGlyph(t, a.status);

    if (a.status === "idle") return div().size(7).mx(3).flex_none().rounded(4).border(1.5).border_color(t.idle ?? t.dim);

    return div().size(7).mx(3).flex_none().rounded(4).bg(t.dim + "00");
  }

  render(cx) {
    const t = theme();

    if (props()?.sortMenu) return this.sortMenu(t);
    const collapsed = narrow();
    const sort = sortOf();
    let list = agents();
    this.listed = new Map(list.map((a) => [a.address, a.status]));
    const all = terminals();
    this.migratePins(all);
    const shown = focused()?.agent;
    const now = Date.now();
    this.track(list, now);
    this.hold(list);
    const byPriority = sort.id === "priority";
    const byProject = sort.id === "project";
    const spaceList = spaces();
    this.refreshOrigins(spaceList, cx);
    const urgency = new Map(list.map((a) => [a.address, Math.max(this.rank(a), ...this.tree(all, a.address).map((s) => RANK[kidStatus(s.t, this.listed)] ?? 0))]));
    const rankOf = (a) => urgency.get(a.address);
    const worktreeOf = (a) => this.originLabel(a, spaceList);
    const projectOf = (a) => worktreeOf(a) ?? a.space_name ?? "";
    const projectKey = (a) => `${machineOf(a) ?? ""}/${projectOf(a)}`;

    if (byPriority) list = [...list].sort((x, y) => rankOf(y) - rankOf(x) || this.since(y) - this.since(x) || y.seq - x.seq);

    if (byProject) {
      const projectOrder = new Map();

      for (const a of list) if (!projectOrder.has(projectKey(a))) projectOrder.set(projectKey(a), projectOrder.size);
      // Stable, so a space's agents stay neighbours; a main checkout comes before its worktrees.
      list = [...list].sort((x, y) => projectOrder.get(projectKey(x)) - projectOrder.get(projectKey(y)) || Boolean(worktreeOf(x)) - Boolean(worktreeOf(y)));
    }

    const pinned = list.filter((a) => a.pinned);
    const rest = list.filter((a) => !a.pinned);
    list = [...pinned, ...rest];
    setAgentOrder(list.map((a) => a.address));

    const withKids = (a, i) => {
      const subs = collapsed ? [] : this.tree(all, a.address);
      const r = row(a, i, subs);

      if (this.folded.has(a.address)) return [r, div().h(6).flex_none()];

      return [r, ...subs.map((s) => this.subRow(t, s, shown, byPriority)), div().h(6).flex_none()];
    };

    // The fold chevron; folded, the count too, colored by the most urgent one.
    const fold = (a, subs) => {
      const sts = subs.map((s) => kidStatus(s.t, this.listed));
      const top = sts.reduce((m, s) => ((RANK[s] ?? 0) > (RANK[m] ?? 0) ? s : m), null);
      const open = !this.folded.has(a.address);

      return div()
        .id(`fold-${a.address}`)
        .h(18)
        .px(3)
        .gap(3)
        .flex()
        .items_center()
        .rounded(4)
        .text_size(11)
        .text_color(open ? t.dim : (t[top] ?? t.dim))
        .cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_click((_e, cx) => {
          cx.stop_propagation();

          if (open) this.folded.add(a.address);

          else this.folded.delete(a.address);
          cx.notify();
        })
        .child(svg(`mods/workspace-chrome/chevron-${open ? "down" : "right"}.svg`).size(11).flex_none())
        .when(!open, (el) => el.child(String(subs.length)));
    };

    const tabs = spaceList.flatMap(s => s.tabs);
    const terminalsByAddress = new Map(all.map((terminal) => [terminal.address, terminal]));
    this.assignAliases([...list, ...list.flatMap((a) => this.tree(all, a.address).map((s) => s.t))], spaceList, all);
    this.syncTabNames(spaceList, panes(), list, cx);

    const location = (a) => {
      const project = worktreeOf(a);

      return project ? `${project} / ${worktreeLabel(a.space_name, project)}` : a.space_name || "";
    };

    // What the row is about: a person's tab name, the agent's task, else where it runs.
    const taskOf = (a) => {
      const project = worktreeOf(a);

      return handName(tabs.find((tab) => tab.id === a.tab), a.program?.name)
        ?? agentTask({ ...a, ...terminalsByAddress.get(a.address) })
        ?? (project ? worktreeLabel(a.space_name, project) : a.space_name)
        ?? a.program?.name
        ?? "";
    };

    const row = (a, i, subs = []) => {
      const task = taskOf(a);
      // Group headers already say where, except in Pinned.
      const place = byProject && !a.pinned ? null : location(a);
      const step = a.status === "working" ? terminalsByAddress.get(a.address)?.report?.msg : null;
      const note = step || place;
      const pic = icon(a.program, 14, t.foreground);
      // An agent on another machine (`vps/t7`) says which.
      const machine = machineOf(a);
      const machineIcon = svg(`mods/my-agents/${machineAsset(machine)}.svg`).size(14).flex_none().text_color(t.dim);

      if (collapsed) {
        return h_flex()
          .id(`ag-${a.address}`)
          .h(26)
          .px(8)
          .flex_none()
          .items_center()
          .gap(4)
          .hover((s) => s.bg(t.hover))
          .on_click(() => run("pane.focus", { pane: a.pane }))
          .child(div().flex_1().min_w(0).whitespace_nowrap().text_right().text_color(t.muted).child(String(i + 1)))
          .child(h_flex().w(14).flex_none().items_center().justify_center().child(this.status(t, a, true)));
      }

      const when = this.since(a);
      const idle = a.status === "idle" && !a.focused;
      const isPinned = a.pinned;

      const pin = div()
        .id(`pin-${a.address}`)
        .flex_none()
        .p(2)
        .rounded(4)
        .text_color(t.dim)
        .cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .tooltip(isPinned ? "Unpin" : "Pin to the top")
        .on_click((_e, cx) => {
          cx.stop_propagation();
          run("terminal.pin", { terminal: a.address, pinned: !isPinned });
          // The row moves away from under the pointer, and no hover-out comes.
          this.hovered = null;
          cx.notify();
        })
        .child(svg(`mods/workspace-chrome/${isPinned ? "pin-off" : "pin"}.svg`).size(13));

      const row1 = h_flex()
        .h(30)
        .flex_none()
        .items_center()
        .gap(6)
          .child(this.stateGlyph(t, a.status))
          .child(div().id(`machine-${a.address}`).flex_none().tooltip(machine ?? "This computer").child(machineIcon))
        .child(div().id(`task-${a.address}`).flex_1().min_w(0).truncate().font_semibold().text_color(idle ? t.muted : t.foreground).tooltip(task).child(task))
        .when(subs.length > 0, el => el.child(fold(a, subs)))
        .when(this.hovered === a.address, el => el.child(pin))
        .when(this.hovered !== a.address && Boolean(when), el => el.child(div().flex_none().text_size(11).text_color(t.dim).child(duration(now - when))))
        .when(a.status === "blocked", el => el.child(this.status(t, a, byPriority && !isPinned)));

      const row2 = h_flex()
        .h(16)
        .flex_none()
        .pl(20)
        .items_center()
        .gap(0)
        .when(Boolean(pic), el => el.child(div().id(`agent-fold-${a.address}`).mr(7)
          .when(subs.length > 0, el => el.on_click((_e, cx) => {
            cx.stop_propagation();

            if (this.folded.has(a.address)) this.folded.delete(a.address);

            else this.folded.add(a.address);
            cx.notify();
          })).child(pic)))
        .child(div().flex_none().text_color(t.muted).child(this.aliases.get(a.address) ?? ""))
        .when(Boolean(note), el => el.child(div().id(`note-${a.address}`).ml(8).min_w(0).truncate().text_color(t.dim).when(Boolean(step && place), (note) => note.tooltip(place)).child(`· ${note}`)));

      return v_flex()
        .id(`ag-${a.address}`)
        .px(8)
        .flex_none()
        .rounded(8)
        .when(a.focused, (el) => el.bg(t.selected))
        .cursor_pointer()
        .hover((s) => s.bg(t.hover))
        .on_hover((on, cx) => {
          if (on) this.hovered = a.address;
          else if (this.hovered === a.address) this.hovered = null;
          cx.notify();
        })
        .on_click(() => run("pane.focus", { pane: a.pane }))
        .children([row1, row2]);
    };

    // Groups in list order: spaces (grouped) or priority sections. Agents of a
    // space are next to each other in agents(), so neighbours make a group.
    const groups = pinned.length ? [{ id: "pinned", label: "Pinned", status: null, members: pinned }] : [];

    const groupOf = (a) => {
      if (byProject) return { id: `pj-${projectKey(a)}`, label: [projectOf(a), machineOf(a)].filter(Boolean).join(" · "), status: null };
      const r = rankOf(a) || RANK.idle;

      return byPriority ? { id: `sec-${r}`, label: SECTION[r], status: SECTION_STATUS[r] } : { id: `sp-${a.space}`, label: a.space_name || "", status: null };
    };

    for (const a of rest) {
      const group = groupOf(a);

      if (groups.at(-1)?.id === group.id) groups.at(-1).members.push(a);
      else groups.push({ ...group, members: [a] });
    }

    const worktreeHeader = (a) => h_flex()
      .h(22)
      .px(8)
      .gap(5)
      .flex_none()
      .items_center()
      .text_size(11)
      .text_color(t.muted)
      .child(svg("mods/workspace-chrome/git-branch.svg").size(11).flex_none().text_color(t.dim))
      .child(div().min_w(0).truncate().child(worktreeLabel(a.space_name, worktreeOf(a))));

    const groupRows = (g) => g.members.flatMap((a, i) => {
      const startsWorktree = byProject && g.id !== "pinned" && worktreeOf(a) && g.members[i - 1]?.space !== a.space;

      return startsWorktree ? [worktreeHeader(a), ...withKids(a, i)] : withKids(a, i);
    });

    // A group's header; it folds the group. Folded, it says how many and the most urgent state.
    const header = (g) => {
      const open = !this.folded.has(g.id);
      const top = g.members.reduce((m, a) => ((RANK[a.status] ?? 0) > (RANK[m] ?? 0) ? a.status : m), null);

      return h_flex()
        .id(g.id)
        .px(8)
        .pt(8)
        .h(30)
        .flex_none()
        .gap(6)
        .items_center()
        .text_size(11)
        .font_medium()
        .cursor_pointer()
        .hover((s) => s.text_color(t.foreground))
        .on_click((_e, cx) => {
          if (open) this.folded.add(g.id);

          else this.folded.delete(g.id);
          cx.notify();
        })
        .child(div().truncate().text_color(t[g.status] ?? t.dim).child(g.label))
        .when(byPriority || !open, (el) => el.child(div().text_color(t.dim).child(String(g.members.length))))
        .child(div().flex_1())
        .when(!open, (el) => el
          .when(!byPriority && top && top !== "idle", (el) => el.child(this.status(t, { status: top }, true)))
          .child(svg("mods/workspace-chrome/chevron-right.svg").size(11).flex_none().text_color(t.dim)));
    };

    const rows = collapsed
      ? list.flatMap(withKids)
      : groups.flatMap((g) => [header(g), ...(this.folded.has(g.id) ? [] : groupRows(g))]);

    this.flushTabRenames(cx);

    return v_flex()
      .size_full()
      .min_h(0)
      .bg(t.chrome)
      .border_t(1)
      .border_color(t.border)
      .text_size(13)
      .when(!collapsed, (el) =>
        el.child(
          h_flex()
            .px(16)
            .h(41)
            .pt(14)
            .pb(5)
            .flex_none()
            .items_center()
            .justify_between()
            .child(div().text_size(11.5).font_medium().text_color(t.dim).child("Agents"))
            .child(
              div()
                .id("ag-sort")
                .text_size(11)
                .text_color(t.dim)
                .hover((s) => s.text_color(t.foreground))
                .on_click(() => openOverlay({ mod: "my-agents", kind: "popup", width: 200, height: 140, props: { sortMenu: true } }))
                .tooltip(`Sort agents: ${sort.label}`)
                .child(svg(`mods/workspace-chrome/${sort.icon}.svg`).size(14)),
            ),
        ),
      )
      .when(list.length === 0 && !collapsed, (el) =>
        el.child(div().px(12).text_size(12).text_color(t.dim).child("No agent status yet. Agents show up here when they report their status. Older versions and agents inside tmux may not.")),
      )
      .child(v_flex().id("ag-list").flex_1().min_h(0).px(collapsed ? 0 : 8).overflow_y_scrollbar().mode("always").children(rows))
      .when(collapsed, (el) =>
        el.child(
          h_flex()
            .h(28)
            .items_center()
            .justify_center()
            .child(
              div()
                .id("collapse")
                .text_size(13)
                .text_color(t.dim)
                .hover((s) => s.text_color(t.foreground))
                .on_click(toggleSidebar)
                .child("»"),
            ),
        ),
      );
  }
}
