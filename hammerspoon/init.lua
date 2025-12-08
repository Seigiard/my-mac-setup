# require "./cmd-layout"
local wm = require("wm-setup")

-----------------------------------------------
-- Hotkeys
-----------------------------------------------
hs.alert.show("Hammerspoon config loaded")
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "r", hs.reload)

hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "left", wm.cycleLeft)
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "right", wm.cycleLeft)
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "up", wm.cycleRight)
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "down", wm.cycleRight)
