--- Window manager.
--
-- Exposes the small high-level API described in the spec:
--   capture(window)          -- gather all state before minimizing
--   tuck(window, edge)       -- coordinate state creation, minimize, shelf
--                                insertion, card creation, and reflow
--   restore(tuckedWindow)    -- THE single restore path (card click,
--                                keyboard search, and reconciliation all
--                                converge here)
--   forget(tuckedWindow)     -- safely remove state/card/shelf membership
--                                without touching the real window
--
-- HOW A WINDOW IS HIDDEN (why there are two mechanisms)
--   The user-facing goal is Cmd+H-style hiding. macOS/Hammerspoon only
--   expose hiding at APPLICATION level (hs.application:hide()/:unhide();
--   there is no per-window hide in hs.window or the Accessibility API),
--   and an unhide reveals every un-minimized window of that app. Tuck's
--   model is one record per WINDOW, so app-wide hiding is only used
--   where it is exactly equivalent to hiding that one window:
--
--     mechanism "hide"     - the window is the ONLY non-minimized window
--                            of its app (on any Space) AND the app has no
--                            other tuck record. Hide/unhide then affects
--                            exactly this one window.
--     mechanism "minimize" - otherwise. Minimizing is truly per-window, so
--                            sibling windows are never hidden or revealed
--                            as a side effect.
--
--   The mechanism is stored on the record; restore() reverses precisely
--   what tuck() did. Invariant: a hide-tucked window is always the ONLY
--   tuck record of its application, so an app-level unhide can never
--   reveal a window that is still supposed to be tucked, and restoring a
--   minimized sibling never needs the app to be unhidden.
--
-- Also owns the internal-restore guards that distinguish a Spoon-
-- initiated unminimize/unhide from a manual one (spec: "do not rely only on
-- arbitrary time delays or sleeps to guess which unminimize caused the
-- event" -- we use an explicit guard keyed by windowID, with only a
-- generous safety-net timer to prevent a permanent leak if an expected
-- event never arrives for some external reason).

local WindowManager = {}
WindowManager.__index = WindowManager

-- Safety-net duration for the internal-restore guard: if we ask macOS to
-- unminimize a window and, for whatever external reason, the expected
-- windowUnminimized event never arrives, this ensures the guard flag
-- cannot leak forever and silently swallow a later *manual* unminimize
-- of a window that happens to reuse the same windowID (exceedingly
-- unlikely in practice, but cheap to guard against).
local RESTORE_GUARD_SAFETY_NET_SECONDS = 3

function WindowManager.new(hsRef, store, cardManager, spaceManager, previewManager, logger, config)
  local self = setmetatable({}, WindowManager)
  self.hs = hsRef
  self.store = store
  self.cardManager = cardManager
  self.spaceManager = spaceManager
  self.previewManager = previewManager
  self.logger = logger
  self.config = config

  self.restoring = {} -- windowID -> true while an internally-initiated unminimize is in flight
  self.hideRestoring = {} -- appKey -> true while an internally-initiated unhide is in flight
  -- Set by init.lua: function() -> array of every known hs.window (all Spaces).
  self.listWindows = nil

  return self
end

function WindowManager:_feedback(message)
  if self.logger then
    self.logger.i("Tuck: " .. message)
  end
  local ok = pcall(function()
    self.hs.alert.show(message, 1.2)
  end)
  if not ok and self.logger then
    self.logger.d("Tuck: hs.alert unavailable for feedback message")
  end
end

--- Is `window` eligible to be tucked? Returns true, or false + a
-- human-readable reason. Uses only documented Hammerspoon eligibility
-- properties (isStandard()) plus the spec's own All-Spaces rule; never
-- maintains a hardcoded per-application blacklist.
function WindowManager:isEligible(window)
  if not window then
    return false, "no focused window"
  end

  local ok, standard = pcall(function()
    return window:isStandard()
  end)
  if not ok then
    return false, "could not determine window eligibility"
  end
  if not standard then
    return false, "window is not a standard application window"
  end

  local okMin, minimized = pcall(function()
    return window:isMinimized()
  end)
  if okMin and minimized then
    return false, "window is already minimized"
  end

  -- All Spaces rejection. hs.spaces is documented as relying on private
  -- APIs; we treat any failure to query it as "cannot verify, so do not
  -- reject" (fail open on the query, never silently mis-tuck though --
  -- see below) but treat a window reported on more than one Space as
  -- unsupported, per spec.
  local okSpaces, spaces = pcall(function()
    return self.hs.spaces.windowSpaces(window)
  end)
  if okSpaces and type(spaces) == "table" and #spaces > 1 then
    return false, "window is assigned to All Spaces, which is unsupported"
  end

  return true
end

--- Gather all state needed to tuck `window`, WITHOUT minimizing it or
-- creating any registry state. Returns a plain capture table, or nil +
-- reason on ineligibility/failure. Order matches the spec: frame, app
-- metadata, icon identity, thumbnail (if enabled/permitted), Space,
-- screen.
function WindowManager:capture(window)
  local eligible, reason = self:isEligible(window)
  if not eligible then
    return nil, reason
  end

  local windowID = window:id()
  if windowID == nil then
    return nil, "window has no id"
  end
  if self.store:getByWindowID(windowID) then
    return nil, "window is already tucked"
  end

  local okFrame, frame = pcall(function()
    return window:frame()
  end)
  if not okFrame or not frame then
    return nil, "could not capture window frame"
  end

  local app = nil
  local okApp
  okApp, app = pcall(function()
    return window:application()
  end)
  if not okApp then
    app = nil
  end

  local appName = nil
  if app then
    local okName, name = pcall(function()
      return app:name()
    end)
    if okName then
      appName = name
    end
  end

  local bundleID = nil
  if app then
    local okBundle, bid = pcall(function()
      return app:bundleID()
    end)
    if okBundle then
      bundleID = bid
    end
  end

  local pid = nil
  if app then
    local okPid, p = pcall(function()
      return app:pid()
    end)
    if okPid then
      pid = p
    end
  end

  local okTitle, title = pcall(function()
    return window:title()
  end)
  if not okTitle then
    title = nil
  end

  local okScreen, screen = pcall(function()
    return window:screen()
  end)
  if not okScreen or not screen then
    return nil, "could not determine window's screen"
  end
  local screenUUID = screen:getUUID()
  if not screenUUID then
    return nil, "could not determine screen identity"
  end

  local spaceID = self.spaceManager:currentSpaceID(screen)
  if spaceID == nil then
    return nil, "could not determine current Space"
  end

  local thumbnail = nil
  if self.config.card.showThumbnail then
    thumbnail = self.previewManager:capture(window, true)
  end

  return {
    windowID = windowID,
    frame = { x = frame.x, y = frame.y, w = frame.w, h = frame.h },
    appName = appName,
    bundleID = bundleID,
    pid = pid,
    appObject = app, -- transient: used by tuck() only, never stored on the record
    title = title,
    screenUUID = screenUUID,
    spaceID = spaceID,
    thumbnail = thumbnail,
  }
end

--- Identity used to key app-level guards: pid when known, else bundle ID.
local function appKey(pid, bundleID)
  return pid or bundleID
end

--- Records currently hidden via app-level hide for this app.
function WindowManager:_hideTuckedRecordsFor(pid, bundleID)
  local out = {}
  for _, rec in ipairs(self.store:allWindows()) do
    if rec.mechanism == "hide" and appKey(rec.pid, rec.bundleID) == appKey(pid, bundleID) then
      out[#out + 1] = rec
    end
  end
  return out
end

--- Any tuck record (either mechanism) for this app.
function WindowManager:_recordsForApp(pid, bundleID)
  local out = {}
  for _, rec in ipairs(self.store:allWindows()) do
    if appKey(rec.pid, rec.bundleID) == appKey(pid, bundleID) then
      out[#out + 1] = rec
    end
  end
  return out
end

--- Number of OTHER windows of the app that are not minimized, on ANY
-- Space. App-level hiding would hide all of them, so any such window
-- rules hiding out. Returns nil when the answer cannot be determined
-- (callers must then assume it is unsafe).
--
-- Enumeration prefers the window filter (sees every Space) via
-- `self.listWindows`; hs.application:allWindows() only sees the current
-- Space and is used solely as a fallback.
function WindowManager:_countOtherLiveWindows(capture)
  local list
  if self.listWindows then
    local ok, l = pcall(self.listWindows)
    if ok and type(l) == "table" then
      list = l
    end
  end
  if not list and capture.appObject then
    local ok, l = pcall(function()
      return capture.appObject:allWindows()
    end)
    if ok and type(l) == "table" then
      list = l
    end
  end
  if not list then
    return nil
  end
  local n = 0
  for _, w in ipairs(list) do
    local okID, wid = pcall(function()
      return w:id()
    end)
    if okID and wid ~= capture.windowID then
      local okApp, wapp = pcall(function()
        return w:application()
      end)
      local samePid, sameBundle = false, false
      if okApp and wapp then
        local okP, wp = pcall(function()
          return wapp:pid()
        end)
        samePid = okP and capture.pid ~= nil and wp == capture.pid
        if capture.pid == nil then
          local okB, wb = pcall(function()
            return wapp:bundleID()
          end)
          sameBundle = okB and wb ~= nil and wb == capture.bundleID
        end
      end
      if samePid or sameBundle then
        local okMin, minimized = pcall(function()
          return w:isMinimized()
        end)
        if not okMin or not minimized then
          n = n + 1
        end
      end
    end
  end
  return n
end

--- Choose how to take `capture`'s window out of view. Returns "hide"
-- only when app-level hiding is exactly equivalent to hiding this one
-- window: it is the app's only non-minimized window (on any Space) and
-- the app has no other tuck record. Otherwise "minimize".
function WindowManager:_chooseMechanism(capture)
  if not capture.appObject or not (capture.pid or capture.bundleID) then
    return "minimize"
  end
  if #self:_recordsForApp(capture.pid, capture.bundleID) > 0 then
    return "minimize"
  end
  local others = self:_countOtherLiveWindows(capture)
  if others == nil or others > 0 then
    return "minimize"
  end
  return "hide"
end

--- Find the live hs.window for a record. hs.window.get() is tried first;
-- if it cannot see the (hidden) window, fall back to the owning
-- application's window list, matched by the stored windowID -- never by
-- app name or "main window".
function WindowManager:_resolveWindow(record)
  local hs = self.hs
  local okGet, win = pcall(function()
    return hs.window.get(record.windowID)
  end)
  if okGet and win then
    return win
  end
  if record.pid then
    local okApp, app = pcall(function()
      return hs.application.applicationForPID(record.pid)
    end)
    if okApp and app then
      local okWins, wins = pcall(function()
        return app:allWindows()
      end)
      if okWins and type(wins) == "table" then
        for _, w in ipairs(wins) do
          local okID, wid = pcall(function()
            return w:id()
          end)
          if okID and wid == record.windowID then
            return w
          end
        end
      end
    end
  end
  return nil
end

--- Tuck `window` into `edge` ("left"|"right"|"top"|"bottom"). Returns
-- true on success, or false + reason. This is the single entry point
-- used by the direction-selection flow.
function WindowManager:tuck(window, edge)
  local capture, reason = self:capture(window)
  if not capture then
    if reason then
      self:_feedback("Can't tuck: " .. reason)
    end
    return false, reason
  end

  local tuckID = self.store:nextTuckID()
  local record = {
    tuckID = tuckID,
    windowID = capture.windowID,
    bundleID = capture.bundleID,
    appName = capture.appName or "Unknown",
    windowTitle = capture.title,
    frame = capture.frame,
    screenUUID = capture.screenUUID,
    spaceID = capture.spaceID,
    edge = edge,
    order = 0,
    thumbnail = capture.thumbnail,
    state = "tucked",
  }

  local mechanism = self:_chooseMechanism(capture)
  record.mechanism = mechanism
  record.pid = capture.pid

  -- Thumbnail and every other piece of state were captured above, BEFORE
  -- the window leaves the screen (a hidden window cannot be captured).
  local okHide, err = pcall(function()
    if mechanism == "hide" then
      local ret = capture.appObject:hide()
      -- Some apps report false even when hide worked (see Hammerspoon
      -- issue #3580), so the return value is deliberately not trusted.
      return ret
    end
    window:minimize()
  end)
  if not okHide then
    -- Hiding failed: never create state for a window that was not
    -- actually hidden (never leave the model believing it was tucked).
    self:_feedback("Tuck failed: could not hide window (" .. tostring(err) .. ")")
    return false, err
  end

  -- Recovery: if anything below fails, the window is already minimized
  -- by macOS but we may not have a card. We still commit the state
  -- record FIRST (before creating the card), so that even if card
  -- creation throws, the window remains recoverable via keyboard search
  -- / a future reconciliation pass rather than becoming an orphaned
  -- minimized window with no Tuck record at all.
  self.store:addWindow(record)

  local okCard, cardErr = pcall(function()
    self.cardManager:reflowRail(record.screenUUID, record.spaceID, record.edge)
  end)
  if not okCard then
    if self.logger then
      self.logger.e("Tuck: card creation failed after minimize; window remains tucked in the registry: " .. tostring(cardErr))
    end
    self:_feedback("Tucked " .. record.appName .. " (card display had a problem, but it can still be restored by name)")
  end

  return true
end

--- THE single restore implementation. Accepts either a tuckID (string)
-- or an already-resolved TuckedWindow record. Every restore path (card
-- click, keyboard search, reconciliation) must call this.
--
-- Reverses exactly the mechanism tuck() used (record.mechanism), then
-- brings THIS window (by windowID, never by app/bundle/"main window") to
-- the front, restores its saved frame, and removes the tuck state.
function WindowManager:restore(tuckIDOrRecord)
  local record
  if type(tuckIDOrRecord) == "table" then
    record = tuckIDOrRecord
  else
    record = self.store:getByTuckID(tuckIDOrRecord)
  end
  if not record then
    -- Already restored/removed by another path (e.g. a click racing a
    -- keyboard restore of the same card): safe no-op.
    return false, "no such tuck record"
  end

  local hs = self.hs
  local windowID = record.windowID
  local win = self:_resolveWindow(record)
  if not win then
    -- Gone without a destroy event (edge case): clean up rather than
    -- leave an orphaned card/record.
    self:forget(record)
    return false, "window no longer exists"
  end

  local app = nil
  if record.mechanism == "hide" then
    local okApp, a = pcall(function()
      return win:application()
    end)
    if okApp then
      app = a
    end
    if not app and record.pid then
      local okPid, a2 = pcall(function()
        return hs.application.applicationForPID(record.pid)
      end)
      if okPid then
        app = a2
      end
    end
    if not app then
      self:_feedback("Failed to restore " .. tostring(record.appName) .. ": application not found")
      return false, "application not found"
    end

    local key = appKey(record.pid, record.bundleID)
    self.hideRestoring[key] = true
    hs.timer.doAfter(RESTORE_GUARD_SAFETY_NET_SECONDS, function()
      self.hideRestoring[key] = nil
    end)
    local okUnhide, unhideErr = pcall(function()
      app:unhide()
    end)
    if not okUnhide then
      self.hideRestoring[key] = nil
      self:_feedback("Failed to restore " .. tostring(record.appName) .. ": " .. tostring(unhideErr))
      return false, unhideErr
    end
  else
    self.restoring[windowID] = true
    hs.timer.doAfter(RESTORE_GUARD_SAFETY_NET_SECONDS, function()
      self.restoring[windowID] = nil
    end)
    local okUnmin, unminErr = pcall(function()
      win:unminimize()
    end)
    if not okUnmin then
      self.restoring[windowID] = nil
      self:_feedback("Failed to restore " .. tostring(record.appName) .. ": " .. tostring(unminErr))
      return false, unminErr
    end
  end

  -- Exact saved frame (failure is logged only: the window is restored
  -- either way and a geometry hiccup must not corrupt state).
  local okFrame, frameErr = pcall(function()
    win:setFrame(record.frame)
  end)
  if not okFrame and self.logger then
    self.logger.w("Tuck: could not restore exact frame for " .. tostring(record.appName) .. ": " .. tostring(frameErr))
  end

  -- Front + focus THIS exact window. Activating the application first
  -- makes it frontmost; focus()/raise() on the window object then picks
  -- the specific window among any siblings.
  local okFocus, focusErr = pcall(function()
    if app then
      app:activate(true)
    else
      local okA, a3 = pcall(function()
        return win:application()
      end)
      if okA and a3 then
        a3:activate(true)
      end
    end
    win:raise()
    win:focus()
  end)
  if not okFocus and self.logger then
    self.logger.w("Tuck: could not focus/raise restored window: " .. tostring(focusErr))
  end

  self:_cleanupRecord(record)
  return true
end

--- Remove state/card/shelf membership for `tuckIDOrRecord` WITHOUT
-- touching the real application window. Safe to call even if the
-- window/application is already gone.
function WindowManager:forget(tuckIDOrRecord)
  local record
  if type(tuckIDOrRecord) == "table" then
    record = tuckIDOrRecord
  else
    record = self.store:getByTuckID(tuckIDOrRecord)
  end
  if not record then
    return
  end
  self:_cleanupRecord(record)
end

--- Shared cleanup: remove from store, destroy card, reflow the rail.
-- Idempotent -- safe even if some of this has already happened.
function WindowManager:_cleanupRecord(record)
  local removed = self.store:removeWindow(record.windowID)
  local tuckID = record.tuckID
  local screenUUID = record.screenUUID
  local spaceID = record.spaceID
  local edge = record.edge

  self.cardManager:destroy(tuckID)

  local okReflow, reflowErr = pcall(function()
    self.cardManager:reflowRail(screenUUID, spaceID, edge)
  end)
  if not okReflow and self.logger then
    self.logger.e("Tuck: reflow after cleanup failed: " .. tostring(reflowErr))
  end
end

--- Called by the window tracker on a windowUnminimized event. Determines
-- whether this was a Spoon-initiated restore (in which case the guard
-- flag is simply cleared -- restore() already did the real cleanup) or a
-- manual user restore (in which case we honor it: remove our state/card
-- but do NOT re-minimize, re-focus, or re-position the window -- the
-- Spoon never fights a user's manual restoration).
function WindowManager:handleUnminimized(window)
  local ok, windowID = pcall(function()
    return window:id()
  end)
  if not ok or windowID == nil then
    return
  end
  if self.restoring[windowID] then
    -- Our own restore() call is already handling this exact record (the
    -- event may arrive before or after the record was removed).
    self.restoring[windowID] = nil
    return
  end
  local record = self.store:getByWindowID(windowID)
  if not record then
    return -- not a tracked tuck; nothing to do
  end

  if self.logger then
    self.logger.i("Tuck: manual unminimize detected for " .. tostring(record.appName) .. "; releasing tuck state")
  end
  self:_cleanupRecord(record)
end

--- Called by the window tracker on a windowDestroyed event. Idempotent
-- and safe even if the card/record no longer exists.
function WindowManager:handleDestroyed(window)
  local ok, windowID = pcall(function()
    return window:id()
  end)
  if not ok or windowID == nil then
    return
  end
  local record = self.store:getByWindowID(windowID)
  if not record then
    return
  end
  if self.logger then
    self.logger.i("Tuck: tucked window destroyed (" .. tostring(record.appName) .. "); cleaning up")
  end
  self:_cleanupRecord(record)
end

--- Application-level unhide (tracker: hs.application.watcher "unhidden").
-- Only matters for a hide-tucked window of that app. If the unhide came
-- from our own restore() the guard is cleared; otherwise the user revealed
-- the app themselves, so the tuck is released WITHOUT re-hiding or
-- repositioning anything.
function WindowManager:handleAppUnhidden(app)
  local okPid, pid = pcall(function()
    return app:pid()
  end)
  local okBundle, bundleID = pcall(function()
    return app:bundleID()
  end)
  pid = okPid and pid or nil
  bundleID = okBundle and bundleID or nil
  if pid == nil and bundleID == nil then
    return
  end
  local key = appKey(pid, bundleID)
  -- Our own restore() sets this guard before unhiding. The event can
  -- arrive before OR after restore() has removed the record, so it is
  -- consumed here regardless of whether a record still exists (otherwise a
  -- stale guard could swallow a later, genuine manual unhide).
  if self.hideRestoring[key] then
    self.hideRestoring[key] = nil
    return
  end
  local records = self:_hideTuckedRecordsFor(pid, bundleID)
  if #records == 0 then
    return -- unrelated app
  end
  for _, record in ipairs(records) do
    if self.logger then
      self.logger.i("Tuck: manual unhide detected for " .. tostring(record.appName) .. "; releasing tuck state")
    end
    self:_cleanupRecord(record)
  end
end

--- Application-level hide. Hides initiated by tuck() are already fully
-- recorded synchronously; a hide the user performs themselves creates
-- no tuck (only the explicit shortcut flow ever creates one).
function WindowManager:handleAppHidden(_app)
end

--- The application quit: every record for it (either mechanism) is stale.
-- Normally each window's destroy event already removed its record; this
-- is the safety net that guarantees no orphaned cards.
function WindowManager:handleAppTerminated(app)
  local okPid, pid = pcall(function()
    return app:pid()
  end)
  local okBundle, bundleID = pcall(function()
    return app:bundleID()
  end)
  pid = okPid and pid or nil
  bundleID = okBundle and bundleID or nil
  local victims = {}
  for _, rec in ipairs(self.store:allWindows()) do
    if (pid ~= nil and rec.pid == pid) or (pid == nil and bundleID ~= nil and rec.bundleID == bundleID) then
      victims[#victims + 1] = rec
    end
  end
  for _, rec in ipairs(victims) do
    self:_cleanupRecord(rec)
  end
  if pid or bundleID then
    self.hideRestoring[appKey(pid, bundleID)] = nil
  end
end

return WindowManager
