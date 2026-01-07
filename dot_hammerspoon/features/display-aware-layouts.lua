local display = require("lib.display")
local windowManager = require("lib.window-manager")
local externalEditor = require("lib.external-editor")

local M = {}

local config = {}
local debounceTimer = nil
local lastDisplayType = nil
local DEBOUNCE_DELAY = 0.5

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

local function applyCurrentDisplaySettings(showAlert)
  if debounceTimer then
    debounceTimer:stop()
  end

  debounceTimer = hs.timer.doAfter(DEBOUNCE_DELAY, function()
    local screen, displayType = display.getPrimaryDisplay()

    if displayType == lastDisplayType then
      return
    end
    lastDisplayType = displayType

    if displayType == "built-in" then
      onBuiltIn(screen, showAlert)
    else
      onExternal(screen, showAlert)
    end
  end)
end

local function triggerBuiltIn()
  lastDisplayType = "built-in"
  local screen = display.getPrimaryDisplay()
  onBuiltIn(screen, true)
end

local function triggerExternal()
  lastDisplayType = "external"
  onExternal(hs.screen.mainScreen(), true)
end

function M.init(cfg)
  config = cfg or {}

  -- Screen change watcher (show alert when display changes)
  local watcher = display.createWatcher(function()
    applyCurrentDisplaySettings(true)
  end)
  watcher:start()

  local mods = { "ctrl", "alt", "cmd" }
  hs.hotkey.bind(mods, "1", triggerBuiltIn)
  hs.hotkey.bind(mods, "2", triggerExternal)

  -- Apply on startup (silent)
  applyCurrentDisplaySettings(false)

  -- Wake watcher (silent)
  hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.screensDidWake then
      applyCurrentDisplaySettings(false)
    end
  end):start()

  -- Polling: check for new windows every 1.5 sec
  local knownWindows = {}

  local function getConfiguredAppNames()
    local apps = {}
    if config.window then
      for appName, _ in pairs(config.window.builtIn or {}) do
        apps[appName] = true
      end
      for appName, _ in pairs(config.window.external or {}) do
        apps[appName] = true
      end
    end
    return apps
  end

  local function checkForNewWindows()
    local configuredApps = getConfiguredAppNames()
    local layout = lastDisplayType == "built-in"
      and config.window.builtIn
      or config.window.external

    if not layout then return end

    local screen = display.getPrimaryDisplay()
    local currentWindows = {}

    for appName, _ in pairs(configuredApps) do
      local app = hs.application.get(appName)
      if app then
        for _, win in ipairs(app:allWindows()) do
          if win:isStandard() then
            local winId = win:id()
            currentWindows[winId] = true

            if not knownWindows[winId] then
              local position = layout[appName]
              if position then
                win:moveToUnit(position, screen)
              end
            end
          end
        end
      end
    end

    knownWindows = currentWindows
  end

  hs.timer.doEvery(1.5, checkForNewWindows)
  checkForNewWindows()
end

return M
