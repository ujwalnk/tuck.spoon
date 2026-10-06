--- Window lifecycle tracker.
--
-- A sensor, not the business-logic owner (per spec). Wraps a single
-- `hs.window.filter` instance and reports ONLY the lifecycle events Tuck
-- acts on -- unminimized, destroyed and focused -- to callbacks supplied by
-- the owner. (windowMinimized, windowMoved and windowTitleChanged are
-- deliberately NOT subscribed: nothing consumes them, and windowMoved in
-- particular fires continuously while any window is dragged.) The tracker
-- exists only while at least one window is tucked (see init.lua
-- :_syncResources). windowFocused feeds window/focus_history.lua so
-- Tuck can restore focus to the exact window that was focused before the
-- one just tucked (see that module for how it distinguishes genuine
-- focus changes from Tuck's own internal ones).
-- This module never decides what those events MEAN; it only forwards
-- them, defensively (any handler error is caught so one misbehaving
-- callback, or one application's unusual Accessibility behavior, can
-- never crash the whole Spoon).
--
-- We track `hs.window.filter.new(true)`: matches every standard
-- application window regardless of which app owns it (rather than one
-- window filter per app), so multiple windows from the same application
-- are all still tracked individually and consistently, per spec's
-- window-identity requirements. `true` is the documented idiom for "do
-- not restrict by any per-application allow/reject rules."

local Tracker = {}
Tracker.__index = Tracker

function Tracker.new(hsRef, logger)
  local self = setmetatable({}, Tracker)
  self.hs = hsRef
  self.logger = logger
  self.wf = nil

  -- Callbacks, each `function(window, appName)`. Set by the owner
  -- (window/manager.lua) before calling :start().
  self.onUnminimized = nil
  self.onDestroyed = nil
  self.onFocused = nil

  -- Application-level callbacks, each `function(app, appName)`. Hiding
  -- (Cmd+H) is an application-wide state, so it is observed with
  -- hs.application.watcher rather than hs.window.filter.
  self.onAppHidden = nil
  self.onAppUnhidden = nil
  self.onAppTerminated = nil
  self.appWatcher = nil

  return self
end

local function safeCall(logger, label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and logger then
    logger.e("Tuck: error in tracker callback (" .. label .. "): " .. tostring(err))
  end
end

--- True while the window filter and application watcher exist.
function Tracker:isRunning()
  return self.wf ~= nil
end

--- Start tracking. Idempotent: a second call while running is a no-op
-- (never a second filter). The owner (init.lua) starts the tracker only
-- while at least one window is tucked and stops it when the last tuck
-- ends, so an idle Spoon holds no window filter or application watcher.
function Tracker:start()
  if self.wf then
    return
  end

  local hs = self.hs
  local this = self

  local ok, wf = pcall(function()
    return hs.window.filter.new(true)
  end)
  if not ok or not wf then
    if self.logger then
      self.logger.e("Tuck: failed to create hs.window.filter: " .. tostring(wf))
    end
    return
  end
  self.wf = wf

  self.wf:subscribe(hs.window.filter.windowUnminimized, function(window, appName)
    safeCall(this.logger, "windowUnminimized", function()
      if this.onUnminimized then
        this.onUnminimized(window, appName)
      end
    end)
  end)

  self.wf:subscribe(hs.window.filter.windowDestroyed, function(window, appName)
    safeCall(this.logger, "windowDestroyed", function()
      if this.onDestroyed then
        this.onDestroyed(window, appName)
      end
    end)
  end)

  self.wf:subscribe(hs.window.filter.windowFocused, function(window, appName)
    safeCall(this.logger, "windowFocused", function()
      if this.onFocused then
        this.onFocused(window, appName)
      end
    end)
  end)

  self:_startAppWatcher()
end

--- Every window the filter currently knows about, across ALL Spaces
-- (hs.window:allWindows()/application:allWindows() only see the current
-- Space). Returns nil if unavailable.
function Tracker:allWindows()
  if not self.wf then
    return nil
  end
  local ok, list = pcall(function()
    return self.wf:getWindows()
  end)
  if ok and type(list) == "table" then
    return list
  end
  return nil
end

--- Start the application watcher (hidden / unhidden / terminated).
function Tracker:_startAppWatcher()
  local hs = self.hs
  local this = self
  local ok, watcher = pcall(function()
    return hs.application.watcher.new(function(appName, eventType, app)
      local handler
      if eventType == hs.application.watcher.hidden then
        handler = this.onAppHidden
      elseif eventType == hs.application.watcher.unhidden then
        handler = this.onAppUnhidden
      elseif eventType == hs.application.watcher.terminated then
        handler = this.onAppTerminated
      end
      if handler then
        safeCall(this.logger, "application:" .. tostring(eventType), handler, app, appName)
      end
    end)
  end)
  if ok and watcher then
    self.appWatcher = watcher
    self.appWatcher:start()
  elseif self.logger then
    self.logger.e("Tuck: failed to create hs.application.watcher: " .. tostring(watcher))
  end
end

--- Stop tracking and release the window filter. Idempotent.
function Tracker:stop()
  if self.appWatcher then
    pcall(function()
      self.appWatcher:stop()
    end)
    self.appWatcher = nil
  end
  if self.wf then
    local ok, err = pcall(function()
      self.wf:unsubscribeAll()
    end)
    if not ok and self.logger then
      self.logger.d("Tuck: window filter unsubscribeAll raised (tolerated): " .. tostring(err))
    end
    self.wf = nil
  end
end

return Tracker
