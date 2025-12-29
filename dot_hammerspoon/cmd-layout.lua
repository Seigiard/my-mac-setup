-- Based on https://github.com/Hammerspoon/hammerspoon/issues/1039#issuecomment-253374355

local module = {}
module.cmdWasPressed = false
module.cmdShouldBeIgnored = false

module.debug = true -- set to true to see debug messages
module.isUsKeyboard = true -- set to true if keyboard is US no ANSI

module.leftCmdPreset = {
  title = "English",
  layout = "English - Seigiard Typography",
  userKeyMapping = "[]"
}
module.rightCmdPreset = {
  title = "Cyrillic",
  layout = "Cyrillic - Seigiard Typography",
  userKeyMapping = "[{\"HIDKeyboardModifierMappingSrc\": 0x700000064, \"HIDKeyboardModifierMappingDst\": 0x700000035}, {\"HIDKeyboardModifierMappingSrc\": 0x700000035, \"HIDKeyboardModifierMappingDst\": 0x700000064}]"
}

-- Listed flag keys events
module.eventwatcher1 = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(e)
  local flags = e:getFlags()
  local modificatorPressed = flags.alt or flags.shift or flags.ctrl or flags.fn

  if flags.cmd and not (modificatorPressed and module.cmdWasPressed)
  then
    module.cmdWasPressed = true
    module.cmdShouldBeIgnored = false
    return false;
  end

  if flags.cmd and (modificatorPressed and module.cmdWasPressed)
  then
    module.cmdShouldBeIgnored = true
    return false;
  end

  if not flags.cmd
  then
    if module.cmdWasPressed and not module.cmdShouldBeIgnored
    then
        local keyCode = e:getKeyCode()

        if keyCode == 0x37 then
          handleCmdClick(module.leftCmdPreset)

        elseif keyCode == 0x36 then
          handleCmdClick(module.rightCmdPreset)
        end
    end

    module.cmdWasPressed = false
    module.cmdShouldBeIgnored = false
  end

  return false;
end):start()

-- Listen all key events except flag keys
module.eventwatcher2 = hs.eventtap.new({"all", hs.eventtap.event.types.flagsChanged}, function(e)
  local flags = e:getFlags()

  if flags.cmd and module.cmdWasPressed then
    module.cmdShouldBeIgnored = true
  end

  return false;
end):start()

log = function(str)
  if module.debug then
      hs.alert.show(str, 0.2)
  end
end

-- Fix the tilde key on US keyboards with Cyrillic layout
-- https://bezdelev.com/hacking/fix-tilde-key-mac/
fixTildaMapping = function(mapping)
  if module.isUsKeyboard then
    hs.execute("hidutil property --set '{\"UserKeyMapping\":" .. mapping .. "}'")
  end
end

handleCmdClick = function(preset)
  log(preset.title)

  if (preset.layout ~= hs.keycodes.currentLayout())
  then
    fixTildaMapping(preset.userKeyMapping)
    hs.keycodes.setLayout(preset.layout)
  end
end