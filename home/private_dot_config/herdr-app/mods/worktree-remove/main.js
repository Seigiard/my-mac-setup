import { View, div } from "gpui-kit";
import { closeOverlay, exec, focused, notify, openOverlay, panes, props, spaces } from "herdr";

// Validates that the focused space is a linked worktree before opening Remove mode.
export default class WorktreeRemove extends View {
  init(_props, cx) {
    const current = focused();
    const overlay = props()?.overlay;

    cx.spawn(async (cx) => {
      const space = current?.space ? spaces().find((s) => s.id === current.space) : null;
      const tabs = new Set((space?.tabs ?? []).map((tab) => tab.id));

      const folder = space
        ? panes().find((pane) => tabs.has(pane.tab) && pane.cwd)?.cwd || space.folder || null
        : null;

      let checked = false;
      let linked = false;
      let failure = "Couldn't check the focused space.";

      try {
        if (space && folder) {
          const options = { cwd: folder, on: space.machine };
          const top = await exec("git", ["rev-parse", "--show-toplevel"], options);
          const common = await exec("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], options);
          const topPath = (top.stdout ?? "").trim();
          const commonPath = (common.stdout ?? "").trim();

          if (top.code === 0 && common.code === 0 && topPath && commonPath) {
            checked = true;
            linked = commonPath !== `${topPath}/.git`;
          } else {
            failure = (top.stderr || common.stderr || top.stdout || common.stdout || failure).trim();
          }
        }
      } catch (error) {
        failure = String(error);
      }

      if (overlay) closeOverlay(overlay);

      if (!space || !folder || !checked || !linked) {
        notify({
          title: !space || !folder
            ? "No focused space to remove."
            : !checked
              ? "Couldn't check the focused space."
              : `${space.name} is the repository's main checkout, not a worktree.`,
          body: !space || !folder || checked ? undefined : failure,
          level: "warning",
        });
      } else {
        openOverlay({
          mod: "worktree",
          kind: "dialog",
          width: 440,
          height: 260,
          props: { space: space.id, action: "remove" },
        });
      }

      cx.notify();
    });
  }

  render() {
    return div();
  }
}
