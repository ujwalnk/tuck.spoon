--- Input state machine.
--
-- One shared shortcut opens ONE command state:
--
--   idle --shortcut--> waitingForCommand
--
--   waitingForCommand:
--     arrow (no search typed yet)  -> tuck focused window toward that edge, idle
--     A-Z                          -> start / narrow the tucked-app search
--                                     (1 match: restore + idle,
--                                      >1: keep waiting, 0: cancel + idle)
--     Esc / timeout                -> cancel, idle
--
-- Once a search letter has been accepted the command is a search:
-- arrows are ignored from then on (they never restore anything, and
-- they must not tuck a window in the middle of choosing one to restore).
--
-- The module has no timers, hotkeys or Hammerspoon dependency; the caller
-- owns the timer and acts on the returned instruction table, e.g.
--   { action = "tuck", edge = "left" }, { action = "restore", tuckID = ... },
--   { action = "restartCommandTimer", matches = {...} }, { action = "cancel" }.

local StateMachine = {}
StateMachine.__index = StateMachine

local ARROW_EDGES = { Left = "left", Right = "right", Up = "top", Down = "bottom" }

function StateMachine.new()
  local self = setmetatable({}, StateMachine)
  self.state = "idle"
  self.search = nil -- { query, matches } while in waitingForCommand
  return self
end

function StateMachine:current()
  return self.state
end

--- The single shortcut was pressed. Always (re)enters a fresh command.
function StateMachine:commandShortcutPressed()
  self:reset()
  self.state = "waitingForCommand"
  self.search = { query = "", matches = {} }
  return { action = "startCommandTimer" }
end

--- True once at least one search letter has been accepted.
function StateMachine:isSearching()
  return self.state == "waitingForCommand" and self.search ~= nil and #self.search.query > 0
end

--- Arrow key ("Left"|"Right"|"Up"|"Down"). Tucks only while no search
-- letter has been typed; never restores anything.
function StateMachine:arrowPressed(arrowName)
  if self.state ~= "waitingForCommand" or self:isSearching() then
    return { action = "none" }
  end
  local edge = ARROW_EDGES[arrowName]
  if not edge then
    return { action = "none" }
  end
  self:reset()
  return { action = "tuck", edge = edge }
end

--- Esc: cancel immediately from the command state.
function StateMachine:escPressed()
  if self.state == "idle" then
    return { action = "none" }
  end
  local wasSearching = self:isSearching()
  self:reset()
  return { action = "cancel", collapseSearch = wasSearching }
end

--- Command timeout elapsed.
function StateMachine:timeoutFired()
  if self.state == "idle" then
    return { action = "none" }
  end
  local wasSearching = self:isSearching()
  self:reset()
  return { action = "cancel", collapseSearch = wasSearching }
end

--- A-Z typed. `matchFn(query)` returns the array of matches
-- ({ tuckID =, appName = }) for the accumulated upper-case query.
function StateMachine:letterPressed(letter, matchFn)
  if self.state ~= "waitingForCommand" then
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
  end
  return { action = "restartCommandTimer", matches = matches }
end

--- A card was clicked: restore it immediately from any state, cancelling
-- any command in progress.
function StateMachine:cardClicked(tuckID)
  local wasActive = self.state ~= "idle"
  self:reset()
  return { action = "restore", tuckID = tuckID, collapseSearch = wasActive }
end

function StateMachine:currentQuery()
  return self.search and self.search.query or nil
end

function StateMachine:currentMatches()
  return self.search and self.search.matches or {}
end

function StateMachine:reset()
  self.state = "idle"
  self.search = nil
end

return StateMachine
