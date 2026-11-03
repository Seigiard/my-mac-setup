import { View, div } from "gpui-kit";
import { closeOverlay, home, props, run } from "herdr";

// Starts a local space in ~/Projects rather than the focused terminal folder.
// Keys cannot pass props, so this wrapper supplies the folder.
export default class SpaceProjects extends View {
  init() {
    const overlay = props()?.overlay;

    if (overlay) closeOverlay(overlay);
    // Empty machine selects this computer, even when a remote space is focused.
    run("space.new", { folder: `${home()}/Projects`, machine: "" });
  }

  render() {
    return div();
  }
}
