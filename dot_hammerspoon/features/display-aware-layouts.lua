local display = require("lib.display")
local windowManager = require("lib.window-manager")
local externalEditor = require("lib.external-editor")

local M = {}

local config = {}
local debounceTimer = nil
local DEBOUNCE_DELAY = 0.5

local function onBuiltIn(screen)
  hs.alert.show("Built-in: " .. screen:name())
  if config.window and config.window.builtIn then
    windowManager.applyLayout(config.window.builtIn, screen)
  end
  if config.zed and config.zed.builtIn then
    externalEditor.updateZedSettings(config.zed.builtIn)
  end
end

local function onExternal(screen)
  hs.alert.show("External: " .. screen:name())
  if config.window and config.window.external then
    windowManager.applyLayout(config.window.external, screen)
  end
  if config.zed and config.zed.external then
    externalEditor.updateZedSettings(config.zed.external)
  end
end

local function applyCurrentDisplaySettings()
  if debounceTimer then
    debounceTimer:stop()
  end

  debounceTimer = hs.timer.doAfter(DEBOUNCE_DELAY, function()
    local screen, displayType = display.getPrimaryDisplay()
    if displayType == "built-in" then
      onBuiltIn(screen)
    else
      onExternal(screen)
    end
  end)
end

local function triggerBuiltIn()
  hs.alert.show("Manual: Built-in display mode")
  local screen = display.getPrimaryDisplay()
  onBuiltIn(screen)
end

local function triggerExternal()
  hs.alert.show("Manual: External display mode")
  onExternal(hs.screen.mainScreen())
end

function M.init(cfg)
  config = cfg or {}

  local watcher = display.createWatcher(applyCurrentDisplaySettings)
  watcher:start()

  local mods = { "ctrl", "alt", "cmd" }
  hs.hotkey.bind(mods, "1", triggerBuiltIn)
  hs.hotkey.bind(mods, "2", triggerExternal)

  -- Apply on startup/wake
  applyCurrentDisplaySettings()
  hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.screensDidWake then
      applyCurrentDisplaySettings()
    end
  end):start()
end

return M
