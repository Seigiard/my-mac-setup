local displayAwareLayouts = require("features.display-aware-layouts")

hs.alert.show("Hammerspoon config loaded")
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "r", hs.reload)

-----------------------------------------------
-- Window positions
-----------------------------------------------
local pos = {
  fullscreen = { x = 0, y = 0, w = 1, h = 1 },
  leftHalf   = { x = 0, y = 0, w = 0.5, h = 1 },
  rightHalf  = { x = 0.5, y = 0, w = 0.5, h = 1 },
  center50   = { x = 0.25, y = 0, w = 0.5, h = 1 },
}

-----------------------------------------------
-- Display-aware layouts
-- Ctrl+Alt+Cmd+1 = Built-in mode
-- Ctrl+Alt+Cmd+2 = External mode
-----------------------------------------------
displayAwareLayouts.init({
  window = {
    builtIn = {
      ["zed"]           = pos.fullscreen,
      ["Figma"]         = pos.fullscreen,
      ["Ghostty"]       = pos.fullscreen,
      ["Slack"]         = pos.fullscreen,
      ["Linear"]        = pos.fullscreen,
      ["zen"]           = pos.fullscreen,
      ["Brave Browser"] = pos.fullscreen,
    },
    external = {
      ["zed"]           = pos.fullscreen,
      ["Figma"]         = pos.leftHalf,
      ["Ghostty"]       = pos.leftHalf,
      ["Slack"]         = pos.center50,
      ["Linear"]        = pos.center50,
      ["zen"]           = pos.rightHalf,
      ["Brave Browser"] = pos.rightHalf,
    },
  },
  zed = {
    builtIn = {
      terminal = { dock = "bottom", default_width = 600, default_height = 500 },
      outline_panel = { default_width = 350 },
      git_panel = { default_width = 350 },
      project_panel = { default_width = 350 },
    },
    external = {
      terminal = { dock = "right", default_width = 1300, default_height = 600 },
      outline_panel = { default_width = 500 },
      git_panel = { default_width = 500 },
      project_panel = { default_width = 500 },
    },
  },
})
