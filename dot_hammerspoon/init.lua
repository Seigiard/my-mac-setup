require "./cmd-layout"

-----------------------------------------------
-- Hotkeys
-----------------------------------------------
hs.alert.show("Hammerspoon config loaded")
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "r", hs.reload)
