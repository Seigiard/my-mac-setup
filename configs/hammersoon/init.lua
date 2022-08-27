local ctrl_opt = {"ctrl", "alt"}
local shift_ctrl_opt = {"shift", "ctrl", "alt"}

hs.hotkey.bind(ctrl_opt, "Left", function()
  local win = hs.window.focusedWindow()
  local f = win:frame()
  local screen = win:screen()
  local max = screen:frame()

  f.x = max.x
  f.y = max.y
  f.w = max.w / 2
  f.h = max.h
  win:setFrame(f)
end)

hs.hotkey.bind(ctrl_opt, "Right", function()
  local win = hs.window.focusedWindow()
  local f = win:frame()
  local screen = win:screen()
  local max = screen:frame()

  f.x = max.x + (max.w / 2)
  f.y = max.y
  f.w = max.w / 2
  f.h = max.h
  win:setFrame(f)
end)

hs.hotkey.bind(ctrl_opt, "Up", function()
  local win = hs.window.focusedWindow()
  local f = win:frame()
  local screen = win:screen()
  local max = screen:frame()

  f.x = max.x
  f.y = max.y
  f.w = max.w
  f.h = max.h
  win:setFrame(f)
end)

-- hs.hotkey.bind(ctrl_opt, "Down", function()
--   local win = hs.window.focusedWindow()
--   win:minimize()
-- end)

hs.hotkey.bind(shift_ctrl_opt, "Left", function()
	-- Get the focused window, its window frame dimensions, its screen frame dimensions,
	-- and the next screen's frame dimensions.
	local focusedWindow = hs.window.focusedWindow()
	local focusedScreenFrame = focusedWindow:screen():frame()
	local nextScreenFrame = focusedWindow:screen():prev():frame()
	local windowFrame = focusedWindow:frame()

	-- Calculate the coordinates of the window frame in the next screen and retain aspect ratio
	windowFrame.x = ((((windowFrame.x - focusedScreenFrame.x) / focusedScreenFrame.w) * nextScreenFrame.w) + nextScreenFrame.x)
	windowFrame.y = ((((windowFrame.y - focusedScreenFrame.y) / focusedScreenFrame.h) * nextScreenFrame.h) + nextScreenFrame.y)
	windowFrame.h = ((windowFrame.h / focusedScreenFrame.h) * nextScreenFrame.h)
	windowFrame.w = ((windowFrame.w / focusedScreenFrame.w) * nextScreenFrame.w)

	-- Set the focused window's new frame dimensions
	focusedWindow:setFrame(windowFrame)
end)

hs.hotkey.bind(shift_ctrl_opt, "Right", function()
	-- Get the focused window, its window frame dimensions, its screen frame dimensions,
	-- and the next screen's frame dimensions.
	local focusedWindow = hs.window.focusedWindow()
	local focusedScreenFrame = focusedWindow:screen():frame()
	local nextScreenFrame = focusedWindow:screen():next():frame()
	local windowFrame = focusedWindow:frame()

	-- Calculate the coordinates of the window frame in the next screen and retain aspect ratio
	windowFrame.x = ((((windowFrame.x - focusedScreenFrame.x) / focusedScreenFrame.w) * nextScreenFrame.w) + nextScreenFrame.x)
	windowFrame.y = ((((windowFrame.y - focusedScreenFrame.y) / focusedScreenFrame.h) * nextScreenFrame.h) + nextScreenFrame.y)
	windowFrame.h = ((windowFrame.h / focusedScreenFrame.h) * nextScreenFrame.h)
	windowFrame.w = ((windowFrame.w / focusedScreenFrame.w) * nextScreenFrame.w)

	-- Set the focused window's new frame dimensions
	focusedWindow:setFrame(windowFrame)
end)