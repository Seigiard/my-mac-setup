import { View, div } from "gpui-kit";
import { exec, terminals } from "herdr";
import { createKeepAwake } from "./keep-awake.js";

export default class KeepAwake extends View {
  init(_props, cx) {
    this.keepAwake = createKeepAwake({
      exec,
      terminals,
      now: () => Date.now(),
    });
    cx.timer.every(5000, (cx) => {
      cx.spawn(async () => {
        await this.keepAwake.tick();
      });
    });
  }

  render() {
    return div();
  }
}
