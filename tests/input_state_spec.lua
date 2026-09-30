local t = require("tests.testkit")
local StateMachine = require("input.state")

local APPS = {
  { tuckID = "safari-1", appName = "Safari" },
  { tuckID = "slack-1", appName = "Slack" },
  { tuckID = "spotify-1", appName = "Spotify" },
  { tuckID = "terminal-1", appName = "Terminal" },
}
local function matchFn(query)
  local out = {}
  for _, item in ipairs(APPS) do
    if item.appName:upper():sub(1, #query) == query then
      out[#out + 1] = item
    end
  end
  return out
end

local function run()
  t.reset()

  -- Shared shortcut enters ONE command state.
  do
    local sm = StateMachine.new()
    t.eq(sm:current(), "idle")
    local res = sm:commandShortcutPressed()
    t.eq(res.action, "startCommandTimer")
    t.eq(sm:current(), "waitingForCommand")
  end

  -- Shortcut + each arrow tucks toward the right edge and returns to idle.
  do
    local mapping = { Left = "left", Right = "right", Up = "top", Down = "bottom" }
    for arrow, edge in pairs(mapping) do
      local sm = StateMachine.new()
      sm:commandShortcutPressed()
      local res = sm:arrowPressed(arrow)
      t.eq(res.action, "tuck", arrow .. " tucks")
      t.eq(res.edge, edge)
      t.eq(sm:current(), "idle")
    end
  end

  -- Arrows outside the command state do nothing (and never restore).
  do
    local sm = StateMachine.new()
    t.eq(sm:arrowPressed("Left").action, "none", "arrow while idle ignored")
  end

  -- Letters outside the command state do nothing.
  do
    local sm = StateMachine.new()
    t.eq(sm:letterPressed("s", matchFn).action, "none")
  end

  -- Esc / timeout cancel.
  do
    local sm = StateMachine.new()
    sm:commandShortcutPressed()
    local res = sm:escPressed()
    t.eq(res.action, "cancel")
    t.isFalse(res.collapseSearch)
    t.eq(sm:current(), "idle")

    sm:commandShortcutPressed()
    res = sm:timeoutFired()
    t.eq(res.action, "cancel")
    t.eq(sm:current(), "idle")
    t.eq(sm:timeoutFired().action, "none", "stray timeout while idle is harmless")
  end

  -- Unique first letter restores immediately.
  do
    local sm = StateMachine.new()
    sm:commandShortcutPressed()
    local res = sm:letterPressed("t", matchFn)
    t.eq(res.action, "restore")
    t.eq(res.tuckID, "terminal-1")
    t.isTrue(res.collapseSearch)
    t.eq(sm:current(), "idle")
  end

  -- Multiple matches keep waiting (and ask for a timer restart); more letters narrow.
  do
    local sm = StateMachine.new()
    sm:commandShortcutPressed()
    local res = sm:letterPressed("S", matchFn)
    t.eq(res.action, "restartCommandTimer", "search timeout resets after each accepted character")
    t.eq(#res.matches, 3)
    t.eq(sm:current(), "waitingForCommand")
    t.isTrue(sm:isSearching())
    t.eq(sm:currentQuery(), "S")

    res = sm:letterPressed("p", matchFn)
    t.eq(res.action, "restore", "SP narrows to Spotify")
    t.eq(res.tuckID, "spotify-1")

    -- further-letter narrowing: S -> SL -> restores Slack
    sm:commandShortcutPressed()
    sm:letterPressed("s", matchFn)
    res = sm:letterPressed("l", matchFn)
    t.eq(res.tuckID, "slack-1")
  end

  -- Multi-letter narrowing keeps resetting the timer while >1 match.
  do
    local apps2 = { { tuckID = "a", appName = "Safari" }, { tuckID = "b", appName = "Safari Technology" } }
    local function mf(q)
      local out = {}
      for _, i in ipairs(apps2) do
        if i.appName:upper():sub(1, #q) == q then out[#out + 1] = i end
      end
      return out
    end
    local sm = StateMachine.new()
    sm:commandShortcutPressed()
    t.eq(sm:letterPressed("s", mf).action, "restartCommandTimer")
    t.eq(sm:letterPressed("a", mf).action, "restartCommandTimer")
    t.eq(sm:letterPressed("f", mf).action, "restartCommandTimer")
    t.eq(sm:currentQuery(), "SAF")
  end

  -- Zero matches cancels and collapses.
  do
    local sm = StateMachine.new()
    sm:commandShortcutPressed()
    local res = sm:letterPressed("z", matchFn)
    t.eq(res.action, "cancel")
    t.isTrue(res.collapseSearch)
    t.eq(sm:current(), "idle")
  end

  -- Once searching, arrows are ignored: they neither tuck nor restore.
  do
    local sm = StateMachine.new()
    sm:commandShortcutPressed()
    sm:letterPressed("s", matchFn)
    for _, arrow in ipairs({ "Left", "Right", "Up", "Down" }) do
      t.eq(sm:arrowPressed(arrow).action, "none", arrow .. " ignored during search")
    end
    t.eq(sm:current(), "waitingForCommand", "search survives stray arrows")
  end

  -- Esc/timeout during an active search collapse expanded cards.
  do
    local sm = StateMachine.new()
    sm:commandShortcutPressed()
    sm:letterPressed("s", matchFn)
    local res = sm:escPressed()
    t.eq(res.action, "cancel")
    t.isTrue(res.collapseSearch)

    sm:commandShortcutPressed()
    sm:letterPressed("s", matchFn)
    res = sm:timeoutFired()
    t.isTrue(res.collapseSearch)
  end

  -- Non-letters are ignored without disturbing the command.
  do
    local sm = StateMachine.new()
    sm:commandShortcutPressed()
    t.eq(sm:letterPressed("5", matchFn).action, "none")
    t.eq(sm:current(), "waitingForCommand")
    t.isFalse(sm:isSearching())
  end

  -- Card click restores from any state and cancels a search.
  do
    local sm = StateMachine.new()
    sm:commandShortcutPressed()
    sm:letterPressed("s", matchFn)
    local res = sm:cardClicked("clicked")
    t.eq(res.action, "restore")
    t.eq(res.tuckID, "clicked")
    t.isTrue(res.collapseSearch)
    t.eq(sm:current(), "idle")

    res = sm:cardClicked("again")
    t.eq(res.action, "restore")
    t.isFalse(res.collapseSearch)
  end

  -- Re-pressing the shortcut mid-search starts a fresh command.
  do
    local sm = StateMachine.new()
    sm:commandShortcutPressed()
    sm:letterPressed("s", matchFn)
    sm:commandShortcutPressed()
    t.isFalse(sm:isSearching())
    t.eq(sm:arrowPressed("Left").action, "tuck", "fresh command accepts an arrow again")
  end

  t.report("input_state_spec")
  return #t.failures == 0
end

return run
