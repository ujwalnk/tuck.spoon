local t = require("tests.testkit")
local FocusHistory = require("window.focus_history")

local function run()
  t.reset()

  -- The worked example from the spec: A -> B -> C, tuck C -> previous is B.
  do
    local fh = FocusHistory.new()
    fh:onWindowFocused("A")
    fh:onWindowFocused("B")
    fh:onWindowFocused("C")
    t.eq(fh:previousWindowID("C"), "B", "previous of C is B")
  end

  -- Two different applications: focus B, then A (different app), tuck A -> B.
  do
    local fh = FocusHistory.new()
    fh:onWindowFocused("appB-win")
    fh:onWindowFocused("appA-win")
    t.eq(fh:previousWindowID("appA-win"), "appB-win")
  end

  -- Same application, two windows: Safari A then Safari B, tuck B -> A.
  do
    local fh = FocusHistory.new()
    fh:onWindowFocused("safari-A")
    fh:onWindowFocused("safari-B")
    t.eq(fh:previousWindowID("safari-B"), "safari-A")
  end

  -- Three windows, same app: A (previous), B (current), C (another).
  -- Tuck B -> A becomes previous; C must never be picked.
  do
    local fh = FocusHistory.new()
    fh:onWindowFocused("safari-C")
    fh:onWindowFocused("safari-A")
    fh:onWindowFocused("safari-B")
    local prev = fh:previousWindowID("safari-B")
    t.eq(prev, "safari-A", "the immediately-previous window wins, not an arbitrary sibling")
    t.isFalse(prev == "safari-C")
  end

  -- No previous window (fresh history, or only the current window ever
  -- recorded): a safe nil, never an arbitrary pick.
  do
    local fh = FocusHistory.new()
    t.isNil(fh:previousWindowID("only"), "empty history yields no candidate")
    fh:onWindowFocused("only")
    t.isNil(fh:previousWindowID("only"), "excluding the sole entry yields no candidate")
  end

  -- Re-focusing an already-recorded window moves it to the top rather
  -- than duplicating (A, B, A -> tucking A's NEW focus should treat B as
  -- previous only once; re-entry doesn't create a stale ghost).
  do
    local fh = FocusHistory.new()
    fh:onWindowFocused("A")
    fh:onWindowFocused("B")
    fh:onWindowFocused("A")
    t.eq(#fh:snapshot(), 2, "re-focusing dedupes rather than growing")
    t.eq(fh:previousWindowID("A"), "B")
  end

  -- isValidFn: an invalid immediate-previous is skipped in favor of the
  -- next valid one further back, rather than giving up entirely.
  do
    local fh = FocusHistory.new()
    fh:onWindowFocused("A")
    fh:onWindowFocused("stale") -- e.g. since destroyed
    fh:onWindowFocused("C")
    local valid = { A = true, C = true }
    local prev = fh:previousWindowID("C", function(id)
      return valid[id] == true
    end)
    t.eq(prev, "A", "an invalid candidate is skipped, not treated as 'no previous'")
  end

  -- forget() removes a window everywhere (tucked, or destroyed) so it
  -- can never be offered as a future previous-window candidate.
  do
    local fh = FocusHistory.new()
    fh:onWindowFocused("A")
    fh:onWindowFocused("B")
    fh:forget("B")
    t.eq(#fh:snapshot(), 1)
    t.eq(fh:previousWindowID("A"), nil, "forgotten window is never offered, and nothing else remains")
    fh:onWindowFocused("C")
    t.eq(fh:previousWindowID("C"), "A", "the surviving, non-forgotten entry is still a valid candidate")
  end

  -- Suppression: Tuck's own focus() must not be recorded as a genuine
  -- transition, and the caller's own :record() is authoritative.
  do
    local fh = FocusHistory.new()
    fh:onWindowFocused("A")
    fh:onWindowFocused("B") -- current, about to be tucked
    -- Tuck auto-refocuses A: suppress, then record deterministically.
    fh:suppressNextFocus("A")
    fh:record("A")
    t.eq(fh:previousWindowID("B"), "A")
    -- The real OS event for A's focus() arrives later: consumed as a
    -- no-op (suppression already used), not double-recorded/reordered.
    local before = fh:snapshot()
    fh:onWindowFocused("A")
    local after = fh:snapshot()
    t.eq(#after, #before, "the resulting real event does not disturb the history")
    for i = 1, #before do
      t.eq(after[i], before[i], "entry " .. i .. " unchanged")
    end
  end

  -- Suppression only consumes ONE event, and only for that windowID.
  do
    local fh = FocusHistory.new()
    fh:onWindowFocused("A")
    fh:suppressNextFocus("A")
    fh:onWindowFocused("A") -- consumed
    fh:onWindowFocused("A") -- genuine this time
    t.eq(#fh:snapshot(), 1, "second focus of A is recorded normally")

    fh:onWindowFocused("B") -- unrelated window is never suppressed
    t.eq(#fh:snapshot(), 2)
  end

  -- clearSuppression: safety net when the expected event never arrives.
  do
    local fh = FocusHistory.new()
    fh:suppressNextFocus("X")
    fh:clearSuppression("X")
    fh:onWindowFocused("X")
    t.eq(#fh:snapshot(), 1, "clearing the suppression lets a later focus record normally")
  end

  -- Bounded size: only the most recent maxSize entries are kept, and the
  -- most-recent-first scan still works correctly at the boundary.
  do
    local fh = FocusHistory.new(3)
    fh:onWindowFocused("A")
    fh:onWindowFocused("B")
    fh:onWindowFocused("C")
    fh:onWindowFocused("D")
    t.eq(#fh:snapshot(), 3, "history is capped")
    t.isNil((function()
      for _, id in ipairs(fh:snapshot()) do
        if id == "A" then
          return true
        end
      end
    end)(), "the oldest entry was evicted")
    t.eq(fh:previousWindowID("D"), "C")
  end

  -- nil-safety: nil windowIDs are simply ignored everywhere.
  do
    local fh = FocusHistory.new()
    fh:onWindowFocused(nil)
    fh:record(nil)
    fh:forget(nil)
    fh:suppressNextFocus(nil)
    fh:clearSuppression(nil)
    t.eq(#fh:snapshot(), 0)
  end

  t.report("focus_history_spec")
  return #t.failures == 0
end

return run
