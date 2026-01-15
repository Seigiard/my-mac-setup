local display = require("lib.display")
local windowManager = require("lib.window-manager")
local externalEditor = require("lib.external-editor")

local M = {}

local config = {}
local currentMode = nil

local function onBuiltIn(screen, showAlert)
  if showAlert then
    hs.alert.show("Built-in: " .. screen:name())
  end
  if config.window and config.window.builtIn then
    windowManager.applyLayout(config.window.builtIn, screen)
  end
  if config.zed and config.zed.builtIn then
    externalEditor.updateZedSettings(config.zed.builtIn)
  end
end

local function onExternal(screen, showAlert)
  if showAlert then
    hs.alert.show("External: " .. screen:name())
  end
  if config.window and config.window.external then
    windowManager.applyLayout(config.window.external, screen)
  end
  if config.zed and config.zed.external then
    externalEditor.updateZedSettings(config.zed.external)
  end
end

local function triggerBuiltIn()
  currentMode = "built-in"
  local screen = display.getPrimaryDisplay()
  onBuiltIn(screen, true)
end

local function triggerExternal()
  currentMode = "external"
  onExternal(hs.screen.mainScreen(), true)
end

function M.init(cfg)
  config = cfg or {}

  local mods = { "ctrl", "alt", "cmd" }
  hs.hotkey.bind(mods, "1", triggerBuiltIn)
  hs.hotkey.bind(mods, "2", triggerExternal)
end

return M
