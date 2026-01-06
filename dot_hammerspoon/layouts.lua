local displayDetector = require("display-detector")
local pos = displayDetector.positions

local M = {}

M.builtIn = {
  ["Zed"] = pos.fullscreen,
  ["Figma"] = pos.fullscreen,
  ["Ghostty"] = pos.fullscreen,
  ["Slack"] = pos.fullscreen,
  ["Linear"] = pos.fullscreen,
  ["Zen Browser"] = pos.fullscreen,
  ["Brave Browser"] = pos.fullscreen,
}

M.external = {
  ["Zed"] = pos.fullscreen,
  ["Figma"] = pos.leftHalf,
  ["Ghostty"] = pos.leftHalf,
  ["Slack"] = pos.center50,
  ["Linear"] = pos.center50,
  ["Zen Browser"] = pos.rightHalf,
  ["Brave Browser"] = pos.rightHalf,
}

return M
