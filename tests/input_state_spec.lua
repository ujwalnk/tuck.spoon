local t = require("tests.testkit")
local StateMachine = require("input.state")

local function run()
  t.reset()

  -- Direction flow: idle -> waitingForDirection -> tuck -> idle.
  do
    local sm = StateMachine.new()
    t.eq(sm:current(), "idle")
    local res = sm:tuckShortcutPressed()
    t.eq(res.action, "startDirectionTimer")
    t.eq(sm:current(), "waitingForDirection")

    local tuckRes = sm:arrowPressed("Left")
    t.eq(tuckRes.action, "tuck")
    t.eq(tuckRes.edge, "left")
    t.eq(sm:current(), "idle", "returns to idle after a successful tuck")
  end

  -- All four arrows map to the correct edge.
  do
    local mapping = { Left = "left", Right = "right", Up = "top", Down = "bottom" }
    for arrow, edge in pairs(mapping) do
      local sm = StateMachine.new()
      sm:tuckShortcutPressed()
      local res = sm:arrowPressed(arrow)
      t.eq(res.action, "tuck")
      t.eq(res.edge, edge, "arrow " .. arrow .. " maps to edge " .. edge)
    end
  end

  -- Esc cancels direction mode without modifying anything.
  do
    local sm = StateMachine.new()
    sm:tuckShortcutPressed()
    local res = sm:escPressed()
    t.eq(res.action, "cancel")
    t.isFalse(res.collapseSearch)
    t.eq(sm:current(), "idle")
  end

  -- Timeout cancels direction mode.
  do
    local sm = StateMachine.new()
    sm:tuckShortcutPressed()
    local res = sm:timeoutFired()
    t.eq(res.action, "cancel")
    t.eq(sm:current(), "idle")
  end

  -- Arrow keys do nothing outside of waitingForDirection (never used for untuck).
  do
    local sm = StateMachine.new()
    local res = sm:arrowPressed("Left")
    t.eq(res.action, "none", "arrow key ignored while idle")

    sm:untuckShortcutPressed("screenAndSpace")
    local res2 = sm:arrowPressed("Left")
    t.eq(res2.action, "none", "arrow key ignored while in app-letter search")
    t.eq(sm:current(), "waitingForAppLetter", "search mode unaffected by stray arrow press")
  end

  -- App search: unique first-letter match restores immediately.
  do
    local sm = StateMachine.new()
    sm:untuckShortcutPressed("screenAndSpace")

    local function matchFn(query)
      local all = {
        { tuckID = "safari-1", appName = "Safari" },
        { tuckID = "slack-1", appName = "Slack" },
        { tuckID = "spotify-1", appName = "Spotify" },
        { tuckID = "terminal-1", appName = "Terminal" },
      }
      local out = {}
      for _, item in ipairs(all) do
        if item.appName:upper():sub(1, #query) == query then
          out[#out + 1] = item
        end
      end
      return out
    end

    -- "T" -> unique match (Terminal) -> immediate restore.
    local res = sm:letterPressed("t", matchFn)
    t.eq(res.action, "restore")
    t.eq(res.tuckID, "terminal-1")
    t.eq(sm:current(), "idle")
  end

  -- App search: multiple matches expand/highlight, then narrow to one.
  do
    local sm = StateMachine.new()
    sm:untuckShortcutPressed("screenAndSpace")

    local function matchFn(query)
      local all = {
        { tuckID = "safari-1", appName = "Safari" },
        { tuckID = "slack-1", appName = "Slack" },
        { tuckID = "spotify-1", appName = "Spotify" },
      }
      local out = {}
      for _, item in ipairs(all) do
        if item.appName:upper():sub(1, #query) == query then
          out[#out + 1] = item
        end
      end
      return out
    end

    local res = sm:letterPressed("s", matchFn)
    t.eq(res.action, "restartSearchTimer", "multiple matches keep the search alive")
    t.eq(#res.matches, 3)
    t.eq(sm:current(), "waitingForAppLetter")

    local res2 = sm:letterPressed("a", matchFn)
    t.eq(res2.action, "restore", "second letter narrows to unique Safari match")
    t.eq(res2.tuckID, "safari-1")
    t.eq(sm:current(), "idle")
  end

  -- App search: zero matches cancels and collapses.
  do
    local sm = StateMachine.new()
    sm:untuckShortcutPressed("screenAndSpace")
    local function matchFn(_query)
      return {}
    end
    local res = sm:letterPressed("z", matchFn)
    t.eq(res.action, "cancel")
    t.isTrue(res.collapseSearch)
    t.eq(sm:current(), "idle")
  end

  -- Esc cancels search mode and reports collapseSearch = true.
  do
    local sm = StateMachine.new()
    sm:untuckShortcutPressed("screenAndSpace")
    local res = sm:escPressed()
    t.eq(res.action, "cancel")
    t.isTrue(res.collapseSearch)
    t.eq(sm:current(), "idle")
  end

  -- Timeout cancels search mode and reports collapseSearch = true.
  do
    local sm = StateMachine.new()
    sm:untuckShortcutPressed("screenAndSpace")
    local res = sm:timeoutFired()
    t.eq(res.action, "cancel")
    t.isTrue(res.collapseSearch)
  end

  -- Card click during active search: restores, cancels search, reports
  -- collapseSearch = true so callers know to collapse other expanded cards.
  do
    local sm = StateMachine.new()
    sm:untuckShortcutPressed("screenAndSpace")
    sm:letterPressed("s", function()
      return { { tuckID = "a" }, { tuckID = "b" } }
    end)
    t.eq(sm:current(), "waitingForAppLetter")

    local res = sm:cardClicked("clicked-tuck-id")
    t.eq(res.action, "restore")
    t.eq(res.tuckID, "clicked-tuck-id")
    t.isTrue(res.collapseSearch)
    t.eq(sm:current(), "idle")
  end

  -- Card click while idle: still restores, but collapseSearch is false.
  do
    local sm = StateMachine.new()
    local res = sm:cardClicked("some-tuck-id")
    t.eq(res.action, "restore")
    t.isFalse(res.collapseSearch)
  end

  -- Non-letter input while searching is ignored (no state change, no crash).
  do
    local sm = StateMachine.new()
    sm:untuckShortcutPressed("screenAndSpace")
    local res = sm:letterPressed("5", function()
      return {}
    end)
    t.eq(res.action, "none")
    t.eq(sm:current(), "waitingForAppLetter", "invalid character does not disturb search state")
  end

  -- Re-pressing the tuck shortcut mid-search resets cleanly into direction mode.
  do
    local sm = StateMachine.new()
    sm:untuckShortcutPressed("screenAndSpace")
    local res = sm:tuckShortcutPressed()
    t.eq(res.action, "startDirectionTimer")
    t.eq(sm:current(), "waitingForDirection")
  end

  t.report("input_state_spec")
  return #t.failures == 0
end

return run
