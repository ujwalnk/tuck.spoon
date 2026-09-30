local t = require("tests.testkit")
local defaults = require("config.defaults")

local function run()
  t.reset()
  local D = defaults.defaults
  local function valid(over)
    return defaults.validate(defaults.merge(D, over))
  end

  t.isTrue(defaults.validate(D), "built-in defaults validate")
  t.eq(D.shortcuts.tuck.key, "t")
  t.eq(D.shortcuts.tuck.mods[1], "fn")
  t.isNil(D.shortcuts.untuck, "no separate untuck shortcut")
  t.eq(D.input.commandTimeout, 1.5)
  t.eq(D.search.scope, "screenAndSpace")
  t.isTrue(D.rails.left.peek)
  t.isTrue(D.rails.right.peek)
  t.isFalse(D.rails.top.peek)
  t.isTrue(D.card.peekSize < D.card.edgeRevealSize, "parked shows less than edge reveal")

  -- partial overrides keep sibling defaults
  do
    local m = defaults.merge(D, { shortcuts = { tuck = { mods = { "cmd" }, key = "y" } } })
    t.eq(m.shortcuts.tuck.key, "y")
    local m2 = defaults.merge(D, { card = { showWindowTitle = true } })
    t.isTrue(m2.card.showWindowTitle)
    t.isTrue(m2.card.showAppIcon)
  end

  -- validation failures
  t.isFalse(valid({ shortcuts = { tuck = { key = "t", mods = { "bogus" } } } }))
  t.isFalse(valid({ input = { commandTimeout = -1 } }))
  t.isFalse(valid({ search = { scope = "everywhere" } }))
  t.isFalse(valid({ card = { peekSize = -1 } }))
  t.isFalse(valid({ card = { peekSize = 50, edgeRevealSize = 20 } }), "reveal must be >= peek")
  t.isFalse(valid({ card = { edgeRevealSize = 500 } }), "reveal cannot exceed the card")
  t.isFalse(valid({ card = { edgeTriggerSize = 2, peekSize = 8 } }), "trigger must cover the peek")
  t.isFalse(valid({ rails = { left = { peek = "yes" } } }))
  t.isFalse(valid({ animation = { easing = "bouncy" } }))
  t.isFalse(valid({ animation = { hoverDuration = -1 } }))

  -- Array-valued fields (mods) replace wholesale; ordinary nested tables
  -- still merge through, even when empty (regression test for a bug
  -- where merging {} onto {"fn"} silently kept "fn").
  do
    local m = defaults.merge(D, { shortcuts = { tuck = { mods = {}, key = "f20" } } })
    t.eq(#m.shortcuts.tuck.mods, 0, "empty mods override clears the default modifier")
    t.eq(m.shortcuts.tuck.key, "f20")
    t.isTrue(defaults.validate(m), "a bare, unmodified shortcut is valid")

    local m2 = defaults.merge(D, { shortcuts = { tuck = { mods = { "cmd", "shift" }, key = "t" } } })
    t.eq(#m2.shortcuts.tuck.mods, 2, "a non-empty mods override also replaces, not appends")
  end

  -- migration from the previous schema
  do
    local m = defaults.merge(D, {
      shortcuts = { untuck = { mods = { "cmd", "shift" }, key = "t" } },
      input = { directionTimeout = 2.5, searchTimeout = 3 },
      card = { animationDuration = 0.4 },
    })
    t.isNil(m.shortcuts.untuck, "old untuck shortcut is dropped")
    t.eq(m.shortcuts.tuck.key, "t", "an empty shortcuts.{} after stripping untuck still merges through defaults")
    t.eq(m.input.commandTimeout, 2.5, "directionTimeout migrates to commandTimeout")
    t.isNil(m.input.directionTimeout)
    t.eq(m.animation.hoverDuration, 0.4, "card.animationDuration migrates")
    t.isTrue(defaults.validate(m))
    -- explicit new key wins
    local m2 = defaults.merge(D, { input = { directionTimeout = 9, commandTimeout = 2 } })
    t.eq(m2.input.commandTimeout, 2)
  end

  -- merge deep-copies
  do
    local m = defaults.merge(D, {})
    m.card.showAppIcon = false
    t.isTrue(D.card.showAppIcon)
  end

  t.report("config_defaults_spec")
  return #t.failures == 0
end

return run
