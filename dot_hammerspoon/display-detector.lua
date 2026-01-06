local M = {}
M.debug = true

function M.isBuiltIn(screen)
  local name = screen:name() or ""
  return name:find("Built%-in") or name:find("Color LCD")
end

function M.getPrimaryDisplay()
  local screens = hs.screen.allScreens()
  for _, screen in ipairs(screens) do
    if M.isBuiltIn(screen) then
      return screen, "built-in"
    end
  end
  return screens[1], "external"
end

local onBuiltIn = function() end
local onExternal = function() end

local function applyCurrentDisplaySettings()
  local screen, displayType = M.getPrimaryDisplay()
  if displayType == "built-in" then
    onBuiltIn(screen)
  else
    onExternal(screen)
  end
end

local function triggerBuiltIn()
  hs.alert.show("Manual: Built-in display mode")
  onBuiltIn(hs.screen.mainScreen())
end

local function triggerExternal()
  hs.alert.show("Manual: External display mode")
  onExternal(hs.screen.mainScreen())
end

function M.init(config)
  onBuiltIn = config.onBuiltIn or onBuiltIn
  onExternal = config.onExternal or onExternal

  hs.screen.watcher.new(applyCurrentDisplaySettings):start()

  hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "1", triggerBuiltIn)
  hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "2", triggerExternal)
end

-----------------------------------------------
-- Window Layouts
-----------------------------------------------
M.positions = {
  fullscreen = { x = 0, y = 0, w = 1, h = 1 },
  leftHalf   = { x = 0, y = 0, w = 0.5, h = 1 },
  rightHalf  = { x = 0.5, y = 0, w = 0.5, h = 1 },
  center50   = { x = 0.25, y = 0, w = 0.5, h = 1 },
}

function M.applyLayout(layout, screen)
  for appName, position in pairs(layout) do
    local app = hs.application.get(appName)
    if app then
      local wins = app:allWindows()
      for _, win in ipairs(wins) do
        if win:isStandard() then
          win:moveToUnit(position, screen)
        end
      end
    end
  end
end

return M
