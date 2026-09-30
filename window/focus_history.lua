--- Focus history.
--
-- A small most-recently-focused stack of windowIDs, used to answer one
-- question: "which window was focused immediately before the one being
-- tucked?" -- so tucking can restore focus to that exact window, never
-- to an arbitrary sibling window or application.
--
-- Pure Lua, no Hammerspoon dependency: the caller (window/tracker.lua via
-- window/manager.lua) feeds it genuine focus events through
-- :onWindowFocused(), and window/manager.lua supplies its own validity
-- check when asking :previousWindowID() for a candidate (existence,
-- visibility, and "not itself a currently-tucked window" all live in
-- window/manager.lua, which is the only place that knows about hs.window
-- and the Tuck registry).
--
-- DISTINGUISHING GENUINE FOCUS FROM TUCK'S OWN
--   Tuck itself calls window:focus() in two places: restoring a tucked
--   window, and this module's whole reason for existing -- automatically
--   refocusing the previous window after a tuck. Neither must be
--   recorded as if the user had freely chosen to focus that window,
--   because the resulting OS focus-changed event fires asynchronously
--   and, left alone, would just re-confirm what the caller already knows
--   (a redundant dedupe/reorder) -- but recording it via the raw event
--   makes the history's correctness depend on event delivery order and
--   timing. Instead the caller:
--     1. calls :suppressNextFocus(windowID) immediately before issuing
--        its own window:focus(),
--     2. immediately calls :record(windowID) itself -- deterministic,
--        not dependent on the OS event ever arriving,
--     3. lets the (now suppressed) real event, if and when it arrives,
--        be silently consumed by :onWindowFocused() as a no-op.
--   A safety-net timer (owned by the caller, same pattern as the
--   restore/hide guards elsewhere) clears a stale suppression flag if a
--   focus() call failed silently and no event was ever going to arrive.

local FocusHistory = {}
FocusHistory.__index = FocusHistory

local DEFAULT_MAX_SIZE = 10

function FocusHistory.new(maxSize)
  local self = setmetatable({}, FocusHistory)
  self.maxSize = maxSize or DEFAULT_MAX_SIZE
  self.stack = {} -- windowIDs, most-recently-focused LAST
  self.suppressed = {} -- windowID -> true: next :onWindowFocused() for it is ignored
  return self
end

--- Record `windowID` as the most-recently-focused window (dedupe: any
-- existing occurrence moves to the top rather than duplicating).
function FocusHistory:record(windowID)
  if windowID == nil then
    return
  end
  for i = #self.stack, 1, -1 do
    if self.stack[i] == windowID then
      table.remove(self.stack, i)
    end
  end
  self.stack[#self.stack + 1] = windowID
  while #self.stack > self.maxSize do
    table.remove(self.stack, 1)
  end
end

--- Called for every genuine (or apparently genuine) focus event. Honors
-- a pending suppression exactly once, then is a plain :record().
function FocusHistory:onWindowFocused(windowID)
  if windowID == nil then
    return
  end
  if self.suppressed[windowID] then
    self.suppressed[windowID] = nil
    return
  end
  self:record(windowID)
end

--- Mark the NEXT :onWindowFocused() for `windowID` to be ignored (Tuck is
-- about to focus it itself; the caller will :record() the correct state
-- directly instead of relying on the resulting OS event).
function FocusHistory:suppressNextFocus(windowID)
  if windowID ~= nil then
    self.suppressed[windowID] = true
  end
end

--- Clear a pending suppression without waiting for the event (safety net
-- for when the expected event never arrives -- e.g. the focus() call
-- itself failed). Idempotent.
function FocusHistory:clearSuppression(windowID)
  if windowID ~= nil then
    self.suppressed[windowID] = nil
  end
end

--- Remove every occurrence of `windowID` (it was tucked, or destroyed, or
-- is otherwise no longer an appropriate focus target/history entry).
-- Idempotent.
function FocusHistory:forget(windowID)
  if windowID == nil then
    return
  end
  for i = #self.stack, 1, -1 do
    if self.stack[i] == windowID then
      table.remove(self.stack, i)
    end
  end
  self.suppressed[windowID] = nil
end

--- The most-recently-focused windowID that is not `excludeWindowID` and,
-- if `isValidFn` is given, for which `isValidFn(windowID)` is true.
-- Scans from most- to least-recent so a single invalid/stale entry
-- cannot hide a genuinely valid one further back. Returns nil if there
-- is no such entry (the caller's safe fallback: focus nothing).
function FocusHistory:previousWindowID(excludeWindowID, isValidFn)
  for i = #self.stack, 1, -1 do
    local id = self.stack[i]
    if id ~= excludeWindowID and (isValidFn == nil or isValidFn(id)) then
      return id
    end
  end
  return nil
end

--- A copy of the current stack, most-recent last (for tests/inspection).
function FocusHistory:snapshot()
  local out = {}
  for i, id in ipairs(self.stack) do
    out[i] = id
  end
  return out
end

function FocusHistory:clear()
  self.stack = {}
  self.suppressed = {}
end

return FocusHistory
