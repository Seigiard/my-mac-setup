local M = {}

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

function M.createWatcher(callback)
  return hs.screen.watcher.new(callback)
end

return M
