local t = require("tests.testkit")
local Shortcut = require("input.shortcut")

local function run()
  t.reset()

  local match = Shortcut._flagsMatch

  do
    local flags = { fn = true, t = false }
    t.isTrue(match(flags, { "fn" }), "fn alone matches a fn-only requirement")
  end

  do
    local flags = { fn = true, cmd = true }
    t.isFalse(match(flags, { "fn" }), "fn+cmd does not match a fn-only requirement (exact match)")
  end

  do
    local flags = { fn = true }
    t.isFalse(match(flags, { "fn", "shift" }), "fn alone does not satisfy fn+shift requirement")
  end

  do
    local flags = { fn = true, shift = true }
    t.isTrue(match(flags, { "fn", "shift" }), "fn+shift matches fn+shift requirement")
  end

  t.report("shortcut_flags_spec")
  return #t.failures == 0
end

return run
