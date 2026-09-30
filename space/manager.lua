--- Space/Screen manager.
--
-- Answers: current Space, current screen, current shelf, available
-- shelves, screen changes, Space changes, which cards should currently be
-- visible. This module does NOT decide whether a window is tucked -- it
-- only manages spatial context, per the spec.
--
-- Depends on `hs.screen`, `hs.spaces`, `hs.screen.watcher`, and
-- `hs.spaces.watcher`. All calls are wrapped defensively: `hs.spaces` is
-- explicitly documented by Hammerspoon as experimental/using private
-- APIs, so every call site here tolerates nil/false returns rather than
-- assuming success.

local SpaceManager = {}
SpaceManager.__index = SpaceManager

function SpaceManager.new(hsRef, logger)
  local self = setmetatable({}, SpaceManager)
  self.hs = hsRef
  self.logger = logger
  self.onScreensChanged = nil -- function() set by owner (Tuck init.lua)
  self.onSpaceChanged = nil -- function() set by owner
  self._screenWatcher = nil
  self._spaceWatcher = nil
  return self
end

--- Current screen: the screen containing the focused window if there is
-- one, else the screen containing the mouse pointer, else the primary
-- screen. Used to resolve "the current screen" for tucking and for
-- screenAndSpace-scoped search.
function SpaceManager:currentScreen()
  local hs = self.hs
  local win = hs.window.focusedWindow()
  if win then
    local ok, screen = pcall(function()
      return win:screen()
    end)
    if ok and screen then
      return screen
    end
  end
  local ok, screen = pcall(function()
    return hs.mouse.getCurrentScreen()
  end)
  if ok and screen then
    return screen
  end
  return hs.screen.mainScreen()
end

--- Current Space ID on a given screen (defaults to the current screen).
-- Returns nil if hs.spaces cannot determine it (defensive: hs.spaces is
-- documented as experimental).
function SpaceManager:currentSpaceID(screen)
  local hs = self.hs
  screen = screen or self:currentScreen()
  local ok, spaceID = pcall(function()
    return hs.spaces.activeSpaceOnScreen(screen)
  end)
  if ok then
    return spaceID
  end
  if self.logger then
    self.logger.w("Tuck: hs.spaces.activeSpaceOnScreen failed: " .. tostring(spaceID))
  end
  return nil
end

--- The "current shelf" identity: { screenUUID, spaceID }.
function SpaceManager:currentShelfIdentity()
  local screen = self:currentScreen()
  local screenUUID = screen and screen:getUUID() or nil
  local spaceID = self:currentSpaceID(screen)
  return screenUUID, spaceID
end

--- Every currently-connected screen's UUID, for reconciliation after a
-- screen-layout change.
function SpaceManager:allScreenUUIDs()
  local out = {}
  for _, screen in ipairs(self.hs.screen.allScreens()) do
    local uuid = screen:getUUID()
    if uuid then
      out[uuid] = true
    end
  end
  return out
end

--- All spaceIDs associated with a given screenUUID's screen, if that
-- screen is still connected. Used to decide whether a shelf's screen is
-- still around after a layout change.
function SpaceManager:spaceIDsForScreenUUID(screenUUID)
  local hs = self.hs
  for _, screen in ipairs(hs.screen.allScreens()) do
    if screen:getUUID() == screenUUID then
      local ok, spaces = pcall(function()
        return hs.spaces.spacesForScreen(screenUUID)
      end)
      if ok and spaces then
        return spaces
      end
      return nil
    end
  end
  return nil -- screen no longer connected
end

--- The frame to place cards within for a given screen: work area or full
-- frame, per configuration. Screens with negative coordinates (left/above
-- the primary screen) are handled correctly because we always use the
-- screen's own frame/work area rather than assuming an origin.
function SpaceManager:areaForScreen(screen, useWorkArea)
  if useWorkArea then
    return screen:frame() -- hs.screen:frame() IS the visible work area (excludes menu bar/dock)
  end
  return screen:fullFrame()
end

--- Start watching for screen-layout and Space changes. `onScreensChanged`
-- and `onSpaceChanged` are callbacks with no arguments; the owner is
-- expected to re-resolve shelf membership/visibility itself using the
-- other methods on this manager (this module never touches tuck state).
function SpaceManager:start(onScreensChanged, onSpaceChanged)
  self:stop() -- idempotent: never double-register watchers
  local hs = self.hs

  self.onScreensChanged = onScreensChanged
  self.onSpaceChanged = onSpaceChanged

  self._screenWatcher = hs.screen.watcher.new(function()
    if self.onScreensChanged then
      local ok, err = pcall(self.onScreensChanged)
      if not ok and self.logger then
        self.logger.e("Tuck: error in screen-changed handler: " .. tostring(err))
      end
    end
  end)
  self._screenWatcher:start()

  local ok, spacesWatcher = pcall(function()
    return hs.spaces.watcher.new(function(_newSpaceNumber)
      if self.onSpaceChanged then
        local ok2, err2 = pcall(self.onSpaceChanged)
        if not ok2 and self.logger then
          self.logger.e("Tuck: error in space-changed handler: " .. tostring(err2))
        end
      end
    end)
  end)
  if ok and spacesWatcher then
    self._spaceWatcher = spacesWatcher
    self._spaceWatcher:start()
  elseif self.logger then
    self.logger.w("Tuck: hs.spaces.watcher unavailable; Space-change reconciliation disabled")
  end
end

--- Stop and release all watchers. Idempotent.
function SpaceManager:stop()
  if self._screenWatcher then
    self._screenWatcher:stop()
    self._screenWatcher = nil
  end
  if self._spaceWatcher then
    self._spaceWatcher:stop()
    self._spaceWatcher = nil
  end
end

return SpaceManager
