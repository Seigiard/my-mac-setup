require "./cmd-layout"

-----------------------------------------------
-- Reload config on write
-----------------------------------------------
local function reload_config()
  hs.reload()
end

hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", reload_config):start()
hs.alert.show("Hammerspoon config (re)loaded")