local M = {}

local ZED_SETTINGS = os.getenv("HOME") .. "/.config/zed/settings.json"

local function deepMerge(target, source)
  for k, v in pairs(source) do
    if type(v) == "table" and type(target[k]) == "table" then
      deepMerge(target[k], v)
    else
      target[k] = v
    end
  end
  return target
end

local function stripTrailingCommas(str)
  return str:gsub(",%s*}", "}"):gsub(",%s*%]", "]")
end

function M.updateZedSettings(config, settingsPath)
  local path = settingsPath or ZED_SETTINGS

  local file = io.open(path, "r")
  if not file then
    hs.alert.show("Zed settings not found: " .. path)
    return false
  end

  local content = file:read("*a")
  file:close()

  local cleanJson = stripTrailingCommas(content)
  local settings = hs.json.decode(cleanJson)
  if not settings then
    hs.alert.show("Failed to parse Zed settings.json")
    return false
  end

  deepMerge(settings, config)

  local tmpPath = "/tmp/zed-settings.json"
  local tmpFile = io.open(tmpPath, "w")
  if not tmpFile then
    hs.alert.show("Cannot create temp file")
    return false
  end
  tmpFile:write(hs.json.encode(settings))
  tmpFile:close()

  local output, status, _, rc = hs.execute("/opt/homebrew/bin/jq '.' " .. tmpPath, true)
  if not status or rc ~= 0 then
    hs.alert.show("jq error: " .. tostring(rc) .. " " .. tostring(output))
    return false
  end

  local outFile = io.open(path, "w")
  if not outFile then
    hs.alert.show("Cannot write to " .. path)
    return false
  end
  outFile:write(output)
  outFile:close()

  os.remove(tmpPath)
  return true
end

return M
