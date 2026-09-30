local t = require("tests.testkit")
local defaults = require("config.defaults")

local function run()
  t.reset()

  do
    local ok, err = defaults.validate(defaults.defaults)
    t.isTrue(ok, "built-in defaults must validate cleanly: " .. tostring(err))
  end

  do
    local merged = defaults.merge(defaults.defaults, { shortcuts = { tuck = { mods = { "cmd" }, key = "y" } } })
    t.eq(merged.shortcuts.tuck.key, "y")
    t.eq(merged.shortcuts.untuck.key, "t", "unrelated nested defaults survive a partial override")
  end

  do
    local merged = defaults.merge(defaults.defaults, { card = { showWindowTitle = true } })
    t.isTrue(merged.card.showWindowTitle)
    t.isTrue(merged.card.showAppIcon, "sibling card options keep their defaults")
  end

  do
    local ok, err = defaults.validate(defaults.merge(defaults.defaults, { shortcuts = { tuck = { key = "t", mods = { "bogus" } } } }))
    t.isFalse(ok, "unknown modifier must fail validation")
  end

  do
    local ok = defaults.validate(defaults.merge(defaults.defaults, { input = { directionTimeout = -1 } }))
    t.isFalse(ok, "negative timeout must fail validation")
  end

  do
    local ok = defaults.validate(defaults.merge(defaults.defaults, { search = { scope = "everywhere" } }))
    t.isFalse(ok, "invalid search scope must fail validation")
  end

  -- Mutating a merged copy must never affect the shared defaults table.
  do
    local merged = defaults.merge(defaults.defaults, {})
    merged.card.showAppIcon = false
    t.isTrue(defaults.defaults.card.showAppIcon, "merge() must deep-copy, not alias, the defaults table")
  end

  t.report("config_defaults_spec")
  return #t.failures == 0
end

return run
