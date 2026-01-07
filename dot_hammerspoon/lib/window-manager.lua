local M = {}

function M.applyLayout(layout, screen)
  local positioned = false
  for appName, position in pairs(layout) do
    local app = hs.application.get(appName)
    if app then
      for _, win in ipairs(app:allWindows()) do
        if win:isStandard() then
          win:moveToUnit(position, screen)
          positioned = true
        end
      end
    end
  end
  return positioned
end

return M
