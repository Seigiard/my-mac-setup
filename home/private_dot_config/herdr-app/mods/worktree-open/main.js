import { View, div } from "gpui-kit";
import { closeOverlay, focused, openOverlay, panes, props } from "herdr";

// Opens the shipped worktree mod in Open mode for the focused space.
// Keys cannot pass props, so this wrapper supplies the action and folder.
export default class WorktreeOpen extends View {
  init() {
    const current = focused();
    const folder = current?.cwd ?? panes().find((pane) => pane.focused)?.cwd;
    const overlay = props()?.overlay;

    if (overlay) closeOverlay(overlay);
    openOverlay({
      mod: "worktree",
      kind: "dialog",
      width: 560,
      height: 480,
      props: { space: current?.space, folder, action: "open" },
    });
  }

  render() {
    return div();
  }
}
