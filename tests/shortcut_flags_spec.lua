local t = require("tests.testkit")
local Shortcut = require("input.shortcut")

local function run()
  t.reset()

  local match = Shortcut._flagsMatch

  do
    t.isTrue(match({ alt = true }, { "alt" }), "Option alone matches an Option-only requirement")
    t.isFalse(match({ alt = true, cmd = true }, { "alt" }), "Option+Cmd does not match (exact match)")
    t.isFalse(match({ alt = true }, { "alt", "shift" }), "Option alone does not satisfy Option+Shift")
    t.isTrue(match({ alt = true, shift = true }, { "alt", "shift" }))
    t.isFalse(match({ fn = true }, { "alt" }), "a stray fn flag never satisfies anything")
  end

  -- The shortcut layer only ever uses hs.hotkey (no keyboard eventtap).
  do
    package.loaded["tests.mock_hs"] = nil
    local mock = require("tests.mock_hs")
    local sc = Shortcut.new(mock)
    local fired = 0
    sc:bind({ mods = { "alt" }, key = "f3" }, function() fired = fired + 1 end)
    sc:bind({ mods = { "alt" }, key = "f3" }, function() fired = fired + 1 end)
    local live = 0
    for _, hk in ipairs(mock._hotkeys) do if not hk.deleted then live = live + 1 end end
    t.eq(live, 1, "re-binding never leaves a duplicate hotkey")
    t.eq(#mock._eventtaps, 0, "no eventtap is created for the shortcut")
    mock._pressHotkey({ "alt" }, "f3")
    t.eq(fired, 1)
    sc:unbindAll(); sc:unbindAll()
    t.isFalse(mock._pressHotkey({ "alt" }, "f3"), "unbound")
  end

  t.report("shortcut_flags_spec")
  return #t.failures == 0
end

return run
