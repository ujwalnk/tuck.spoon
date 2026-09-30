--- Input state machine.
--
-- States: idle -> waitingForDirection -> idle
--         idle -> waitingForAppLetter -> idle
--
-- This module is intentionally free of timers/hotkeys/Hammerspoon: the
-- caller (input/shortcut.lua + init.lua) owns the actual timer objects and
-- calls into this state machine's pure transition functions, then acts on
-- the returned instruction. This split is what allows the state machine
-- itself to be unit tested deterministically (no real clocks).
--
-- Every public method returns a table describing what the caller should do,
-- e.g. { action = "tuck", edge = "left" } or { action = "restore", tuckID = "x" }
-- or { action = "none" }. The state machine never calls into Hammerspoon or
-- any card/window API directly.

local StateMachine = {}
StateMachine.__index = StateMachine

local VALID_EDGES = { Left = "left", Right = "right", Up = "top", Down = "bottom" }

function StateMachine.new()
  local self = setmetatable({}, StateMachine)
  self.state = "idle"
  self.search = nil -- { query, scope, candidates, matches }
  return self
end

function StateMachine:current()
  return self.state
end

--- Called when the configured tuck shortcut fires.
function StateMachine:tuckShortcutPressed()
  if self.state ~= "idle" then
    -- Re-entering direction mode from any other state simply resets to a
    -- fresh direction wait; we never stack modes.
    self:reset()
  end
  self.state = "waitingForDirection"
  return { action = "startDirectionTimer" }
end

--- Called when the configured untuck shortcut fires.
function StateMachine:untuckShortcutPressed(scope)
  if self.state ~= "idle" then
    self:reset()
  end
  self.state = "waitingForAppLetter"
  self.search = { query = "", scope = scope, candidates = {}, matches = {} }
  return { action = "startSearchTimer" }
end

--- Arrow key pressed while in waitingForDirection. `arrowName` is one of
-- "Left", "Right", "Up", "Down" (matching hs.keycodes naming).
-- Returns { action = "tuck", edge = ... } or { action = "none" } if not
-- applicable in the current state.
function StateMachine:arrowPressed(arrowName)
  if self.state ~= "waitingForDirection" then
    return { action = "none" }
  end
  local edge = VALID_EDGES[arrowName]
  if not edge then
    return { action = "none" }
  end
  self:reset()
  return { action = "tuck", edge = edge }
end

--- Esc pressed. Valid from either waiting state; cancels immediately.
function StateMachine:escPressed()
  if self.state == "idle" then
    return { action = "none" }
  end
  local wasSearching = self.state == "waitingForAppLetter"
  self:reset()
  return { action = "cancel", collapseSearch = wasSearching }
end

--- Timer fired for whichever mode is currently active. Cancels back to
-- idle without modifying anything.
function StateMachine:timeoutFired()
  if self.state == "idle" then
    return { action = "none" }
  end
  local wasSearching = self.state == "waitingForAppLetter"
  self:reset()
  return { action = "cancel", collapseSearch = wasSearching }
end

--- A-Z letter typed while in waitingForAppLetter. `letter` is a single
-- upper-case character. `matchFn(query) -> candidateList` is supplied by
-- the caller (it queries the real card/window registry); this keeps the
-- state machine itself free of any data dependency.
--
-- matchFn should return an array of { tuckID = ..., appName = ... }.
--
-- Returns one of:
--   { action = "restartSearchTimer" }                          -- 2+ matches, keep waiting
--   { action = "restore", tuckID = ... , collapseSearch = true } -- exactly 1 match
--   { action = "cancel", collapseSearch = true }                 -- 0 matches
--   { action = "none" }                                          -- wrong state / invalid letter
function StateMachine:letterPressed(letter, matchFn)
  if self.state ~= "waitingForAppLetter" then
    return { action = "none" }
  end
  if type(letter) ~= "string" or #letter ~= 1 or not letter:match("^[A-Za-z]$") then
    return { action = "none" }
  end

  self.search.query = self.search.query .. letter:upper()
  local matches = matchFn(self.search.query) or {}
  self.search.matches = matches

  if #matches == 0 then
    self:reset()
    return { action = "cancel", collapseSearch = true }
  elseif #matches == 1 then
    local tuckID = matches[1].tuckID
    self:reset()
    return { action = "restore", tuckID = tuckID, collapseSearch = true }
  else
    return { action = "restartSearchTimer", matches = matches }
  end
end

--- A card was clicked directly (bypassing keyboard search). Valid in any
-- state; always restores immediately and cancels any active search.
function StateMachine:cardClicked(tuckID)
  local wasSearching = self.state == "waitingForAppLetter"
  self:reset()
  return { action = "restore", tuckID = tuckID, collapseSearch = wasSearching }
end

function StateMachine:currentQuery()
  if self.search then
    return self.search.query
  end
  return nil
end

function StateMachine:currentMatches()
  if self.search then
    return self.search.matches
  end
  return {}
end

function StateMachine:reset()
  self.state = "idle"
  self.search = nil
end

return StateMachine
