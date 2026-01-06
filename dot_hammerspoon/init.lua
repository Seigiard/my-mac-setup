-- require "./cmd-layout"
local displayDetector = require("display-detector")
local layouts = require("layouts")

-----------------------------------------------
-- Hotkeys
-----------------------------------------------
hs.alert.show("Hammerspoon config loaded")
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "r", hs.reload)

-----------------------------------------------
-- Display Detection
-----------------------------------------------
displayDetector.init({
  onBuiltIn = function(screen)
    hs.alert.show("Built-in: " .. screen:name())
    displayDetector.applyLayout(layouts.builtIn, screen)
  end,
  onExternal = function(screen)
    hs.alert.show("External: " .. screen:name())
    displayDetector.applyLayout(layouts.external, screen)
  end,
})
