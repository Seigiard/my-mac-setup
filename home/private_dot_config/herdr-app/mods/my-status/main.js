import { View, div, svg } from "gpui-kit";
import { h_flex } from "gpui-base";
import { spaces, agents, theme, run, window, keys, exec, home } from "herdr";

const PROVIDERS = { "\uEC82": "claude", "\uEC81": "codex" };

function parseLimits(output) {
  return output.trim().split(" · ").map((segment) => {
    const provider = PROVIDERS[segment[0]];

    if (!provider) return null;

    return { provider, text: segment.slice(1).trimStart().replace(/\uEABD/g, "⊘") };
  }).filter(Boolean);
}

function sameLimits(previous, next) {
  return previous?.length === next.length && previous.every((limit, i) => limit.provider === next[i].provider && limit.text === next[i].text);
}

export default class WorkspaceStatus extends View {
  init(_props, cx) {
    this.limits = null;
    this.refreshing = false;
    this.refresh(cx);
    cx.timer.every(60000, (cx) => this.refresh(cx));
  }

  refresh(cx) {
    if (this.refreshing) return;

    this.refreshing = true;
    cx.spawn(async (cx) => {
      try {
        const result = await exec(`${home()}/.local/bin/herdr-agent-limits`, []);

        if (result.code !== 0 || !result.stdout.trim()) return;

        const limits = parseLimits(result.stdout);

        if (!limits.length || sameLimits(this.limits, limits)) return;

        this.limits = limits;
        cx.notify();
      } catch {}
      finally { this.refreshing = false; }
    });
  }

  // The palette key as actually bound, not a hardcoded one; without a
  // binding the hint stays useful ("commands") instead of lying.
  hint(_t) {
    const mac = window()?.platform === "macos";
    const mod = { cmd: mac ? "⌘" : "Ctrl+", ctrl: mac ? "⌃" : "Ctrl+", shift: mac ? "⇧" : "Shift+", alt: mac ? "⌥" : "Alt+", option: mac ? "⌥" : "Alt+" };
    const b = keys().find((k) => k.section === "global" && k.action === "app.palette");
    const parts = b && b.keys.endsWith("--") ? [...b.keys.slice(0, -2).split("-"), "-"] : b?.keys.split("-");
    const key = parts && parts.map((p) => mod[p.toLowerCase()] ?? p.toUpperCase()).join("");

    return key ? `${key}  commands` : "commands";
  }

  render() {
    const t = theme();
    const space = spaces().find(s => s.active);
    const list = agents();
    const needs = list.filter(a => a.status === "blocked").length;

    const label = (icon, text) => h_flex().gap(6).items_center().child(svg(`mods/workspace-chrome/${icon}.svg`).size(13)).child(text);

    return h_flex().size_full().px(14).gap(16).items_center().bg(t.chrome).border_t(1).border_color(t.border).text_size(11.8).text_color(t.muted)
      .child(label(space?.machine ? "server" : "monitor", space?.machine ?? "This computer"))
      .when(Boolean(space?.branch), el => el.child(label("branch", space.branch)))
      .child(h_flex().gap(6).items_center().child(div().size(6).rounded(3).bg(t.dim)).child(`${list.length} agents`)
        .when(needs > 0, el => el.child(div().text_color(t.blocked).child(`· ${needs} needs you`))))
      .child(div().flex_1())
      .when(Boolean(this.limits), el => el.child(h_flex().gap(10).items_center().children(this.limits.map(({ provider, text }) =>
        h_flex().gap(4).items_center()
          .child(svg(`icons/${provider}.svg`).size(12).flex_none().text_color(t.muted))
          .child(div().text_color(text.includes("⊘") ? t.blocked : t.muted).child(text)),
      ))))
      .child(div().id("palette").text_color(t.dim).on_click(() => run("app.palette")).child(this.hint(t)));
  }
}
