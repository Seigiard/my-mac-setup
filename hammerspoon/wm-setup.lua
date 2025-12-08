--[[
  Window Stack Cycler
  Cycle through windows on current monitor
  Left: bring from bottom, Right: send to bottom
]]

hs.window.animationDuration = 0

local function rectsIntersect(r1, r2)
  return r1.x < r2.x + r2.w and
      r1.x + r1.w > r2.x and
      r1.y < r2.y + r2.h and
      r1.y + r1.h > r2.y
end

local function getWindowStack()
  local currentScreen = hs.screen.mainScreen()
  local currentScreenId = currentScreen:id()
  local orderedWindows = hs.window.orderedWindows()

  local windows = {}

  for _, win in ipairs(orderedWindows) do
    if win:isStandard() and win:screen():id() == currentScreenId then
      local app = win:application()
      if app then
        table.insert(windows, win)
      end
    end
  end

  local visibleLayer = {}
  local coveredLayer = {}

  for i, win in ipairs(windows) do
    local isCovered = false

    for j = 1, i - 1 do
      if rectsIntersect(win:frame(), windows[j]:frame()) then
        isCovered = true
        break
      end
    end

    if isCovered then
      table.insert(coveredLayer, win)
    else
      table.insert(visibleLayer, win)
    end
  end

  return visibleLayer, coveredLayer
end

local function getDisplayName(win)
  local app = win:application()
  local appName = app:name()
  local title = win:title()

  if title and title ~= "" and title ~= appName then
    return appName .. " - " .. title
  end
  return appName
end

local function positionWindow(targetWin, sourceWin)
  local frame = sourceWin:frame()
  targetWin:setFrame(frame)
end

local function showWindowStack()
  local visibleLayer, coveredLayer = getWindowStack()

  if #visibleLayer == 0 and #coveredLayer == 0 then
    hs.alert.show("No windows")
    return
  end

  local lines = {}

  if #visibleLayer > 0 then
    table.insert(lines, "-- visible --")
    for _, win in ipairs(visibleLayer) do
      table.insert(lines, "  " .. getDisplayName(win))
    end
  end

  if #coveredLayer > 0 then
    table.insert(lines, "-- covered --")
    for _, win in ipairs(coveredLayer) do
      table.insert(lines, "  " .. getDisplayName(win))
    end
  end

  local text = table.concat(lines, "\n")
  hs.pasteboard.setContents(text)
  hs.alert.show(text, 10)
end

-- Left: bring last covered to top
local function cycleLeft()
  local currentWin = hs.window.focusedWindow()
  if not currentWin then
    hs.alert.show("No focused window")
    return
  end

  local _, coveredLayer = getWindowStack()

  if #coveredLayer == 0 then
    hs.alert.show("No covered windows")
    return
  end

  local targetWin = coveredLayer[#coveredLayer]

  positionWindow(targetWin, currentWin)
  targetWin:focus()
end

-- Right: send current to bottom, bring first covered to top
local function cycleRight()
  local currentWin = hs.window.focusedWindow()
  if not currentWin then
    hs.alert.show("No focused window")
    return
  end

  local _, coveredLayer = getWindowStack()

  if #coveredLayer == 0 then
    hs.alert.show("No covered windows")
    return
  end

  local targetWin = coveredLayer[1]
  targetWin:focus()

  positionWindow(targetWin, currentWin)
end

return {
  showWindowStack = showWindowStack,
  getWindowStack = getWindowStack,
  cycleLeft = cycleLeft,
  cycleRight = cycleRight
}
